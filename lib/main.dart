import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF050505),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const PSPlayerApp());
}

class PSPlayerApp extends StatelessWidget {
  const PSPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PS Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF050505),
        primaryColor: const Color(0xFFFF2A2A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF2A2A),
          secondary: Colors.white,
          surface: Color(0xFF111111),
        ),
        textTheme: GoogleFonts.spaceMonoTextTheme(ThemeData.dark().textTheme),
      ),
      home: const PSPlayerHome(),
    );
  }
}

class LocalAudioTrack {
  final String id;
  final String title;
  final String folder;
  final String path;
  final DateTime modified;

  const LocalAudioTrack({
    required this.id,
    required this.title,
    required this.folder,
    required this.path,
    required this.modified,
  });
}

class PSPlayerHome extends StatefulWidget {
  const PSPlayerHome({super.key});

  @override
  State<PSPlayerHome> createState() => _PSPlayerHomeState();
}

class _PSPlayerHomeState extends State<PSPlayerHome>
    with SingleTickerProviderStateMixin {
  final AudioPlayer _player = AudioPlayer();

  List<LocalAudioTrack> _allTracks = [];
  List<LocalAudioTrack> _queue = [];
  Set<String> _favorites = {};
  LocalAudioTrack? _currentTrack;
  int _queueIndex = -1;

  bool _hasPermission = false;
  bool _isScanning = true;
  bool _isPlaying = false;
  bool _isShuffle = false;
  LoopMode _loopMode = LoopMode.all;
  double _speed = 1.0;

  int _tab = 0; // 0: Tracks, 1: Favorites, 2: Folders
  String _search = '';
  String _sortBy = 'TITLE'; // TITLE, RECENT

  // Equalizer UI state
  bool _eqEnabled = true;
  String _preset = 'NOTHING STUDIO';
  List<double> _bands = [3.5, 1.5, -0.5, 2.5, 4.0];
  double _bassBoost = 0.30;

  // Sleep Timer
  Timer? _sleepTimer;
  int? _sleepMins;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  late final AnimationController _waveCtrl;

  static const Set<String> _audioExts = {
    '.mp3',
    '.m4a',
    '.aac',
    '.wav',
    '.flac',
    '.ogg',
    '.opus',
  };

  @override
  void initState() {
    super.initState();
    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    )..repeat(reverse: true);

    _loadFavorites();
    _listenPlayer();
    _requestAndScan();
  }

  @override
  void dispose() {
    _player.dispose();
    _waveCtrl.dispose();
    _sleepTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('ps_player_fav_paths') ?? [];
    if (!mounted) return;
    setState(() => _favorites = saved.toSet());
  }

  Future<void> _toggleFav(String path) async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      if (_favorites.contains(path)) {
        _favorites.remove(path);
      } else {
        _favorites.add(path);
      }
    });
    await prefs.setStringList('ps_player_fav_paths', _favorites.toList());
  }

  void _listenPlayer() {
    _player.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() => _isPlaying = state.playing);
      if (state.processingState == ProcessingState.completed) {
        _playNext(auto: true);
      }
    });
    _player.positionStream.listen((pos) {
      if (!mounted) return;
      setState(() => _position = pos);
    });
    _player.durationStream.listen((dur) {
      if (!mounted) return;
      setState(() => _duration = dur ?? Duration.zero);
    });
  }

  Future<void> _requestAndScan() async {
    setState(() => _isScanning = true);

    bool granted = true;
    if (Platform.isAndroid) {
      final audio = await Permission.audio.request();
      final storage = await Permission.storage.request();
      granted = audio.isGranted ||
          storage.isGranted ||
          await Permission.audio.isGranted ||
          await Permission.storage.isGranted;
    }

    if (!mounted) return;
    if (!granted) {
      setState(() {
        _hasPermission = false;
        _isScanning = false;
      });
      return;
    }

    setState(() => _hasPermission = true);
    await _scanStorage();
  }

  Future<void> _scanStorage() async {
    final List<LocalAudioTrack> found = [];
    final Set<String> visited = {};

    final List<Directory> roots = [];
    if (Platform.isAndroid) {
      for (final p in [
        '/storage/emulated/0/Music',
        '/storage/emulated/0/Download',
        '/storage/emulated/0/Recordings',
        '/storage/emulated/0/Podcasts',
        '/storage/emulated/0',
      ]) {
        final d = Directory(p);
        if (await d.exists()) roots.add(d);
      }
    } else {
      roots.add(Directory.current);
    }

    Future<void> walk(Directory dir, int depth) async {
      if (depth > 5) return;
      final canon = dir.absolute.path;
      if (visited.contains(canon)) return;
      visited.add(canon);

      try {
        await for (final entity in dir.list(followLinks: false)) {
          final name = entity.path.split('/').last;
          if (name.startsWith('.')) continue;

          if (entity is Directory) {
            await walk(entity, depth + 1);
          } else if (entity is File) {
            final lower = entity.path.toLowerCase();
            final hasExt = _audioExts.any((ext) => lower.endsWith(ext));
            if (!hasExt) continue;

            final stat = await entity.stat();
            if (stat.size < 10240) continue; // skip tiny corrupt files

            final fileName = entity.path.split('/').last;
            final dotIdx = fileName.lastIndexOf('.');
            final cleanTitle =
                dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName;
            final parentFolder = entity.parent.path.split('/').last;

            found.add(
              LocalAudioTrack(
                id: entity.path,
                title: cleanTitle,
                folder: parentFolder.isEmpty ? 'Storage' : parentFolder,
                path: entity.path,
                modified: stat.modified,
              ),
            );
          }
        }
      } catch (_) {
        // Ignore restricted system subfolders
      }
    }

    for (final root in roots) {
      await walk(root, 0);
    }

    // Deduplicate by path
    final Map<String, LocalAudioTrack> uniqueMap = {
      for (final t in found) t.path: t,
    };
    final list = uniqueMap.values.toList();

    if (!mounted) return;
    setState(() {
      _allTracks = list;
      _sortTracks();
      if (_queue.isEmpty) _queue = List.from(_allTracks);
      _isScanning = false;
    });
  }

  void _sortTracks() {
    if (_sortBy == 'TITLE') {
      _allTracks.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    } else {
      _allTracks.sort((a, b) => b.modified.compareTo(a.modified));
    }
  }

  Future<void> _playList(List<LocalAudioTrack> list, int index) async {
    if (index < 0 || index >= list.length) return;
    final track = list[index];
    try {
      setState(() {
        _queue = List.from(list);
        _queueIndex = index;
        _currentTrack = track;
      });
      await _player.setFilePath(track.path);
      await _player.setSpeed(_speed);
      await _player.play();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF181818),
          content: Text('Could not play "${track.title}"'),
        ),
      );
    }
  }

  Future<void> _playNext({bool auto = false}) async {
    if (_queue.isEmpty) return;
    if (auto && _loopMode == LoopMode.one && _currentTrack != null) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    if (auto &&
        _loopMode == LoopMode.off &&
        !_isShuffle &&
        _queueIndex >= _queue.length - 1) {
      await _player.pause();
      await _player.seek(Duration.zero);
      return;
    }
    final next = _isShuffle
        ? Random().nextInt(_queue.length)
        : (_queueIndex + 1) % _queue.length;
    await _playList(_queue, next);
  }

  Future<void> _playPrev() async {
    if (_queue.isEmpty) return;
    if (_position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }
    final prev = (_queueIndex - 1 + _queue.length) % _queue.length;
    await _playList(_queue, prev);
  }

  List<LocalAudioTrack> get _visibleTracks {
    Iterable<LocalAudioTrack> base = _allTracks;
    if (_tab == 1) {
      base = base.where((t) => _favorites.contains(t.path));
    }
    final q = _search.trim().toLowerCase();
    if (q.isNotEmpty) {
      base = base.where(
        (t) =>
            t.title.toLowerCase().contains(q) ||
            t.folder.toLowerCase().contains(q),
      );
    }
    return base.toList();
  }

  void _startSleep(int mins) {
    _sleepTimer?.cancel();
    if (mins == 0) {
      setState(() => _sleepMins = null);
      return;
    }
    setState(() => _sleepMins = mins);
    _sleepTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (!mounted) return;
      setState(() {
        if ((_sleepMins ?? 0) <= 1) {
          _player.pause();
          _sleepMins = null;
          timer.cancel();
        } else {
          _sleepMins = _sleepMins! - 1;
        }
      });
    });
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned(
            top: -110,
            left: -70,
            child: Container(
              width: 310,
              height: 310,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFF2A2A).withOpacity(0.15),
              ),
            ),
          ),
          Positioned(
            bottom: 90,
            right: -90,
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.05),
              ),
            ),
          ),
          Positioned.fill(child: CustomPaint(painter: _DotMatrixPainter())),
          SafeArea(
            child: Column(
              children: [
                _buildHeader(),
                _buildSearchBar(),
                _buildTabs(),
                Expanded(child: _buildBody()),
                if (_currentTrack != null) _buildMiniPlayer(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: Color(0xFFFF2A2A),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PS PLAYER',
                    style: GoogleFonts.dotGothic16(
                      fontSize: 25,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.5,
                    ),
                  ),
                  Text(
                    '${_allTracks.length} OFFLINE FILES',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.5,
                      color: Colors.white.withOpacity(0.45),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              if (_sleepMins != null)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF2A2A).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: const Color(0xFFFF2A2A).withOpacity(0.6),
                    ),
                  ),
                  child: Text(
                    '${_sleepMins}M',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFFF2A2A),
                    ),
                  ),
                ),
              _glassBtn(Icons.graphic_eq_rounded, _openEqualizer),
              const SizedBox(width: 8),
              _glassBtn(Icons.bedtime_outlined, _openSleepSheet),
              const SizedBox(width: 8),
              _glassBtn(Icons.refresh_rounded, _requestAndScan),
            ],
          ),
        ],
      ),
    );
  }

  Widget _glassBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.14)),
        ),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.white.withOpacity(0.12)),
                  ),
                  child: TextField(
                    onChanged: (v) => setState(() => _search = v),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      icon: Icon(
                        Icons.search_rounded,
                        size: 19,
                        color: Colors.white.withOpacity(0.5),
                      ),
                      hintText: 'SEARCH SONGS OR FOLDERS...',
                      hintStyle: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.2,
                        color: Colors.white.withOpacity(0.35),
                      ),
                      border: InputBorder.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              setState(() {
                _sortBy = _sortBy == 'TITLE' ? 'RECENT' : 'TITLE';
                _sortTracks();
              });
            },
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.12)),
              ),
              child: Text(
                _sortBy,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    const tabs = ['TRACKS', 'FAVORITES', 'FOLDERS'];
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: tabs.length,
        itemBuilder: (context, idx) {
          final active = _tab == idx;
          return GestureDetector(
            onTap: () => setState(() => _tab = idx),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active
                    ? const Color(0xFFFF2A2A)
                    : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: active
                      ? const Color(0xFFFF2A2A)
                      : Colors.white.withOpacity(0.1),
                ),
              ),
              child: Text(
                tabs[idx],
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.3,
                  color: active ? Colors.white : Colors.white70,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    if (_isScanning) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF2A2A)),
      );
    }

    if (!_hasPermission) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: Colors.white.withOpacity(0.14)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.folder_open_rounded,
                      size: 48,
                      color: Color(0xFFFF2A2A),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'STORAGE ACCESS REQUIRED',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Allow Music & Audio or Files permission so PS Player can read your local songs.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                    const SizedBox(height: 18),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF2A2A),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onPressed: () async => openAppSettings(),
                      child: const Text(
                        'OPEN SETTINGS',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                    TextButton(
                      onPressed: _requestAndScan,
                      child: const Text(
                        'SCAN AGAIN',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (_tab == 2) return _buildFolders();

    final list = _visibleTracks;
    if (list.isEmpty) {
      return Center(
        child: Text(
          _tab == 1 ? 'NO FAVORITE TRACKS YET' : 'NO AUDIO FILES FOUND',
          style: TextStyle(
            fontSize: 12,
            letterSpacing: 1.6,
            color: Colors.white.withOpacity(0.45),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
      itemCount: list.length,
      itemBuilder: (context, idx) {
        final track = list[idx];
        final isCurrent = _currentTrack?.path == track.path;
        final isFav = _favorites.contains(track.path);

        return GestureDetector(
          onTap: () => _playList(list, idx),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: isCurrent
                  ? const Color(0xFFFF2A2A).withOpacity(0.14)
                  : Colors.white.withOpacity(0.045),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isCurrent
                    ? const Color(0xFFFF2A2A).withOpacity(0.65)
                    : Colors.white.withOpacity(0.08),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.music_note_rounded,
                    color: isCurrent ? const Color(0xFFFF2A2A) : Colors.white54,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: isCurrent
                              ? const Color(0xFFFF2A2A)
                              : Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        track.folder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isCurrent && _isPlaying)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: AnimatedBuilder(
                      animation: _waveCtrl,
                      builder: (_, __) => Row(
                        children: List.generate(3, (bar) {
                          final h = 6 +
                              12 * sin((_waveCtrl.value * pi) + (bar * 1.1));
                          return Container(
                            width: 3,
                            height: h.abs(),
                            margin: const EdgeInsets.symmetric(horizontal: 1.5),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF2A2A),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                IconButton(
                  icon: Icon(
                    isFav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    size: 20,
                    color: isFav ? const Color(0xFFFF2A2A) : Colors.white38,
                  ),
                  onPressed: () => _toggleFav(track.path),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFolders() {
    final Map<String, List<LocalAudioTrack>> grouped = {};
    for (final t in _allTracks) {
      grouped.putIfAbsent(t.folder, () => []).add(t);
    }
    final entries = grouped.entries.toList();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 110),
      itemCount: entries.length,
      itemBuilder: (context, idx) {
        final folder = entries[idx].key;
        final tracks = entries[idx].value;
        return GestureDetector(
          onTap: () => _playList(tracks, 0),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.045),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.09)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF2A2A).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.folder_rounded,
                    color: Color(0xFFFF2A2A),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        folder,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${tracks.length} TRACKS • TAP TO PLAY',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.1,
                          color: Colors.white.withOpacity(0.45),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.play_arrow_rounded, color: Colors.white60),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMiniPlayer() {
    final track = _currentTrack!;
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onTap: _openNowPlaying,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white.withOpacity(0.14),
                    Colors.white.withOpacity(0.05),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF2A2A).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(
                            Icons.music_note_rounded,
                            color: Color(0xFFFF2A2A),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                track.folder,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withOpacity(0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded),
                          onPressed: _playPrev,
                        ),
                        GestureDetector(
                          onTap: () =>
                              _isPlaying ? _player.pause() : _player.play(),
                          child: Container(
                            width: 42,
                            height: 42,
                            decoration: const BoxDecoration(
                              color: Color(0xFFFF2A2A),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded),
                          onPressed: () => _playNext(),
                        ),
                      ],
                    ),
                  ),
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 2.5,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation(Color(0xFFFF2A2A)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openNowPlaying() {
    if (_currentTrack == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setModal) {
          return StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (context, snap) {
              final track = _currentTrack!;
              final pos = snap.data ?? _position;
              final maxMs = max(1, _duration.inMilliseconds).toDouble();
              final curMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);

              return ClipRRect(
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(36)),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 35, sigmaY: 35),
                  child: Container(
                    height: MediaQuery.of(context).size.height * 0.88,
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0A0A).withOpacity(0.88),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(36),
                      ),
                      border: Border.all(color: Colors.white.withOpacity(0.15)),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white30,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'NOW PLAYING // PS OS',
                              style: GoogleFonts.dotGothic16(
                                fontSize: 13,
                                letterSpacing: 2,
                                color: Colors.white70,
                              ),
                            ),
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: _openEqualizer,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF2A2A)
                                          .withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: const Color(0xFFFF2A2A)
                                            .withOpacity(0.6),
                                      ),
                                    ),
                                    child: const Text(
                                      'EQ',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: Color(0xFFFF2A2A),
                                      ),
                                    ),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () {
                                    const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
                                    final next = speeds[
                                        (speeds.indexOf(_speed) + 1) %
                                            speeds.length];
                                    _player.setSpeed(next);
                                    setState(() => _speed = next);
                                    setModal(() {});
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Text(
                                      '${_speed}x',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const Spacer(),
                        Container(
                          width: 240,
                          height: 240,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(34),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    const Color(0xFFFF2A2A).withOpacity(0.28),
                                blurRadius: 45,
                                spreadRadius: 4,
                              ),
                            ],
                            border: Border.all(
                              color: Colors.white.withOpacity(0.2),
                              width: 1.5,
                            ),
                          ),
                          child: const Icon(
                            Icons.album_rounded,
                            size: 110,
                            color: Color(0xFFFF2A2A),
                          ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    track.folder,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.white.withOpacity(0.55),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                _favorites.contains(track.path)
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                color: const Color(0xFFFF2A2A),
                                size: 28,
                              ),
                              onPressed: () {
                                _toggleFav(track.path);
                                setModal(() {});
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: const Color(0xFFFF2A2A),
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                            trackHeight: 4,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7,
                            ),
                          ),
                          child: Slider(
                            value: curMs,
                            max: maxMs,
                            onChanged: (v) {
                              _player.seek(Duration(milliseconds: v.toInt()));
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _fmt(pos),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white60,
                                ),
                              ),
                              Text(
                                _fmt(_duration),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white60,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              icon: Icon(
                                Icons.shuffle_rounded,
                                color: _isShuffle
                                    ? const Color(0xFFFF2A2A)
                                    : Colors.white54,
                              ),
                              onPressed: () {
                                setState(() => _isShuffle = !_isShuffle);
                                setModal(() {});
                              },
                            ),
                            IconButton(
                              iconSize: 38,
                              icon: const Icon(Icons.skip_previous_rounded),
                              onPressed: () async {
                                await _playPrev();
                                setModal(() {});
                              },
                            ),
                            GestureDetector(
                              onTap: () {
                                _isPlaying ? _player.pause() : _player.play();
                                setModal(() {});
                              },
                              child: Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFF2A2A),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFFFF2A2A)
                                          .withOpacity(0.45),
                                      blurRadius: 22,
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  _isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 38,
                                ),
                              ),
                            ),
                            IconButton(
                              iconSize: 38,
                              icon: const Icon(Icons.skip_next_rounded),
                              onPressed: () async {
                                await _playNext();
                                setModal(() {});
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                _loopMode == LoopMode.one
                                    ? Icons.repeat_one_rounded
                                    : Icons.repeat_rounded,
                                color: _loopMode == LoopMode.off
                                    ? Colors.white54
                                    : const Color(0xFFFF2A2A),
                              ),
                              onPressed: () {
                                setState(() {
                                  if (_loopMode == LoopMode.all) {
                                    _loopMode = LoopMode.one;
                                  } else if (_loopMode == LoopMode.one) {
                                    _loopMode = LoopMode.off;
                                  } else {
                                    _loopMode = LoopMode.all;
                                  }
                                });
                                setModal(() {});
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _openEqualizer() {
    final presets = <String, List<double>>{
      'NOTHING STUDIO': [3.5, 1.5, -0.5, 2.5, 4.0],
      'FLAT': [0.0, 0.0, 0.0, 0.0, 0.0],
      'BASS BOOST': [6.5, 4.5, 0.0, 1.5, 2.5],
      'ROCK': [4.5, 2.5, -1.5, 3.0, 5.0],
      'VOCAL': [-2.0, 1.5, 5.0, 3.5, 0.5],
    };
    const freqLabels = ['60Hz', '230Hz', '910Hz', '3.6kHz', '14kHz'];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setModal) {
          return ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(34)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              child: Container(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 30),
                decoration: BoxDecoration(
                  color: const Color(0xFF0C0C0C).withOpacity(0.92),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(34)),
                  border: Border.all(color: Colors.white.withOpacity(0.15)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white30,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'EQUALIZER // DSP',
                          style: GoogleFonts.dotGothic16(
                            fontSize: 18,
                            letterSpacing: 2,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Switch(
                          value: _eqEnabled,
                          activeColor: const Color(0xFFFF2A2A),
                          onChanged: (v) {
                            setState(() => _eqEnabled = v);
                            setModal(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: presets.entries.map((entry) {
                          final active = _preset == entry.key;
                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                _preset = entry.key;
                                _bands = List.from(entry.value);
                              });
                              setModal(() {});
                            },
                            child: Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: active
                                    ? const Color(0xFFFF2A2A)
                                    : Colors.white.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Text(
                                entry.key,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(5, (i) {
                        return Column(
                          children: [
                            Text(
                              '${_bands[i] >= 0 ? '+' : ''}${_bands[i].toStringAsFixed(1)}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white70,
                              ),
                            ),
                            SizedBox(
                              height: 150,
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: Slider(
                                  value: _bands[i],
                                  min: -10,
                                  max: 10,
                                  activeColor: _eqEnabled
                                      ? const Color(0xFFFF2A2A)
                                      : Colors.white30,
                                  onChanged: !_eqEnabled
                                      ? null
                                      : (v) {
                                          setState(() {
                                            _preset = 'CUSTOM';
                                            _bands[i] = v;
                                          });
                                          setModal(() {});
                                        },
                                ),
                              ),
                            ),
                            Text(
                              freqLabels[i],
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        );
                      }),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'BASS & LOUDNESS BOOST',
                          style: TextStyle(fontSize: 11, letterSpacing: 1.2),
                        ),
                        Text(
                          '${(_bassBoost * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFFF2A2A),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _bassBoost,
                      activeColor: const Color(0xFFFF2A2A),
                      onChanged: (v) {
                        setState(() => _bassBoost = v);
                        setModal(() {});
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openSleepSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'SLEEP TIMER',
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              children: [0, 15, 30, 45, 60].map((m) {
                return ChoiceChip(
                  label: Text(m == 0 ? 'OFF' : '$m MIN'),
                  selected: (_sleepMins ?? 0) == m,
                  selectedColor: const Color(0xFFFF2A2A),
                  onSelected: (_) {
                    _startSleep(m);
                    Navigator.pop(context);
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DotMatrixPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withOpacity(0.04);
    for (double x = 0; x < size.width; x += 22) {
      for (double y = 0; y < size.height; y += 22) {
        canvas.drawCircle(Offset(x, y), 1.0, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
