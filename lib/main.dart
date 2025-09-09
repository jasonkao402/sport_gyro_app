// Flutter Sensor Recorder
// Author: 伊莉亞（兔耳女僕）
// 功能：以 60 Hz（約每 16.667 ms）採樣、連續記錄 5 秒的加速度計、陀螺儀與磁力計資料，輸出 CSV 檔案，並可分享。
// 使用說明（快速）：
// 1. 把下面檔案存為 `lib/main.dart` 到一個 Flutter 專案。
// 2. 在 pubspec.yaml 加上相依套件（bottom of this file has snippet）。
// 3. flutter pub get，然後執行（Android / iOS）。
// 4. 點 Start 開始錄製，完成後會在 app 文件目錄產生 CSV，並會顯示分享按鈕。

// 注意事項：
// - sensors_plus 實際硬體傳感器回傳頻率可能受裝置限制。這個程式使用 Timer 做固定速率採樣，取最新一次的 sensor event 值，盡量達到 60 Hz。
// - CSV 儲存在應用程式文件目錄（getApplicationDocumentsDirectory）。若要存到 Downloads 或公開目錄，需額外處理權限。
// - 若要在真機使用，記得在 Android 的 build.gradle 與 iOS 的 Info.plist 加入必要權限（磁力計、加速度等通常不需額外權限，但若存至外部需 WRITE_EXTERNAL_STORAGE）。

import 'dart:async';
import 'dart:io';
// import 'dart:nativewrappers/_internal/vm/lib/ffi_native_type_patch.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const SensorRecorderApp());
}

class SensorRecorderApp extends StatelessWidget {
  const SensorRecorderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IMU Sensor Recorder',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.lightBlue),
      ),
      home: const RecorderPage(),
    );
  }
}

class RecorderPage extends StatefulWidget {
  const RecorderPage({super.key});

  @override
  State<RecorderPage> createState() => _RecorderPageState();
}

class _RecorderPageState extends State<RecorderPage> {
  // 最新感測器值（由 stream 更新）
  AccelerometerEvent? _latestAcc;
  GyroscopeEvent? _latestGyro;
  MagnetometerEvent? _latestMag;

  // 訂閱
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;

  // 記錄用陣列
  final List<List<String>> _rows = [];

  bool _isRecording = false;
  bool _isMonitoring = false;
  int _sampleCount = 0;
  String? _lastSavedPath;

  Timer? _sampleTimer;
  int _targetHz = 60;
  double _durationSec = 5.0; // 錄製秒數

  @override
  void initState() {
    super.initState();
    _startListeningStreams();
  }

  void _startListeningStreams() {
    // final intervalMicros = (1000000 / _targetHz).round();
    _accSub =
        accelerometerEventStream(
          samplingPeriod: SensorInterval.gameInterval,
        ).listen((event) {
          _latestAcc = event;
        });
    _gyroSub =
        gyroscopeEventStream(
          samplingPeriod: SensorInterval.gameInterval,
        ).listen((event) {
          _latestGyro = event;
        });
    _magSub =
        magnetometerEventStream(
          samplingPeriod: SensorInterval.gameInterval,
        ).listen((event) {
          _latestMag = event;
        });
  }

  void _stopListeningStreams() {
    _accSub?.cancel();
    _gyroSub?.cancel();
    _magSub?.cancel();
    _accSub = null;
    _gyroSub = null;
    _magSub = null;
  }

  Future<void> _startMonitoring() async {
    if (_isMonitoring) return;
    setState(() {
      _isMonitoring = true;
      _sampleCount = 0;
    });
    final stopwatch = Stopwatch()..start();
    final uiInterval = (1000 / 30).round();
    _sampleTimer = Timer.periodic(Duration(milliseconds: uiInterval), (timer) {
      // 更新 UI
      if (mounted) setState(() {});
      if (stopwatch.elapsedMilliseconds >= (_durationSec * 1000).round()) {
        timer.cancel();
        stopwatch.stop();
        setState(() {
          _isMonitoring = false;
        });
      }
    });
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;
    setState(() {
      _isRecording = true;
      _rows.clear();
      _sampleCount = 0;
      _lastSavedPath = null;
    });

    // CSV header
    _rows.add([
      'timestamp_iso',
      'epoch_ms',
      'acc_x',
      'acc_y',
      'acc_z',
      'gyro_x',
      'gyro_y',
      'gyro_z',
      'mag_x',
      'mag_y',
      'mag_z',
    ]);

    final stopwatch = Stopwatch()..start();
    final intervalMicros = (1000000 / _targetHz).round();
    // 使用 Timer.periodic 做穩定採樣
    _sampleTimer = Timer.periodic(Duration(microseconds: intervalMicros), (
      timer,
    ) {
      final now = DateTime.now().toUtc();
      final epochMs = now.millisecondsSinceEpoch;

      // 取最新值，若還沒取得則填 NaN
      final acc = _latestAcc;
      final gyro = _latestGyro;
      final mag = _latestMag;

      _rows.add([
        now.toIso8601String(),
        epochMs.toString(),
        (acc?.x.toStringAsFixed(6)) ?? 'NaN',
        (acc?.y.toStringAsFixed(6)) ?? 'NaN',
        (acc?.z.toStringAsFixed(6)) ?? 'NaN',
        (gyro?.x.toStringAsFixed(6)) ?? 'NaN',
        (gyro?.y.toStringAsFixed(6)) ?? 'NaN',
        (gyro?.z.toStringAsFixed(6)) ?? 'NaN',
        (mag?.x.toStringAsFixed(6)) ?? 'NaN',
        (mag?.y.toStringAsFixed(6)) ?? 'NaN',
        (mag?.z.toStringAsFixed(6)) ?? 'NaN',
      ]);

      _sampleCount = _rows.length - 1; // exclude header

      // 更新 UI
      if (mounted) setState(() {});

      if (stopwatch.elapsedMilliseconds >= (_durationSec * 1000).round()) {
        timer.cancel();
        stopwatch.stop();
        _finishRecording();
      }
    });
  }

  Future<void> _shareCsv() async {
    if (_lastSavedPath == null) return;
    await Share.shareXFiles([XFile(_lastSavedPath!)]);
  }

  Future<void> _finishRecording() async {
    setState(() {
      _isRecording = false;
    });

    // 將 _rows 轉成 CSV 字串
    final csvBuffer = StringBuffer();
    for (final row in _rows) {
      csvBuffer.writeln(row.join(','));
    }

    // 取得 app 文件目錄
    final dir = await getExternalStorageDirectory();
    final now = DateTime.now();
    final filename =
        'sensor_${now.toIso8601String().replaceAll(':', '').replaceAll('.', '')}.csv';
    final file = File('${dir?.path}/$filename');

    await file.writeAsString(csvBuffer.toString());

    setState(() {
      _lastSavedPath = file.path;
    });
  }

  @override
  void dispose() {
    _sampleTimer?.cancel();
    _stopListeningStreams();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final acc = _latestAcc;
    final gyro = _latestGyro;
    final mag = _latestMag;

    return Scaffold(
      appBar: AppBar(
        title: const Text('IMU sensor recorder'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '狀態：${_isRecording ? '錄製中...' : '閒置'}',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _isRecording ? null : _startRecording,
              child: const Text('Start Recording'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _isMonitoring ? null : _startMonitoring,
              child: Text(
                _isMonitoring ? 'Stop Monitoring' : 'Start Monitoring',
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: (_lastSavedPath != null) ? _shareCsv : null,
              child: const Text('Share CSV'),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _isRecording
                  ? (_sampleCount / (_targetHz * _durationSec))
                  : 0.0,
              minHeight: 8,
            ),
            const SizedBox(height: 16),
            // Row(
            //   children: [
            // targetHz input
            const Text('Sample Rate (Hz) (5~500):'),
            SizedBox(
              width: 60,
              child: TextFormField(
                enabled: !_isRecording,
                initialValue: _targetHz.toString(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 8,
                  ),
                ),
                onChanged: (val) {
                  final parsed = int.tryParse(val);
                  if (parsed != null && parsed >= 5 && parsed <= 500) {
                    setState(() {
                      _targetHz = parsed;
                    });
                  }
                },
              ),
            ),
            const SizedBox(width: 16),
            // input seconds
            const Text('Record Duration (seconds):'),
            SizedBox(
              width: 60,
              child: TextFormField(
                enabled: !_isRecording,
                initialValue: _durationSec.toString(),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 8,
                  ),
                ),
                onChanged: (val) {
                  final parsed = double.tryParse(val);
                  if (parsed != null && parsed > 0) {
                    setState(() {
                      _durationSec = parsed.toDouble();
                    });
                  }
                },
              ),
            ),

            //   ],
            // ),
            const SizedBox(height: 16),
            Text('樣本數：$_sampleCount / ${(_targetHz * _durationSec).round()}'),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Sensor Values:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Accelerometer:\nx=${acc?.x.toStringAsFixed(4) ?? 'N/A'}, y=${acc?.y.toStringAsFixed(4) ?? 'N/A'}, z=${acc?.z.toStringAsFixed(4) ?? 'N/A'}',
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Gyroscope:\nx=${gyro?.x.toStringAsFixed(4) ?? 'N/A'}, y=${gyro?.y.toStringAsFixed(4) ?? 'N/A'}, z=${gyro?.z.toStringAsFixed(4) ?? 'N/A'}',
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Magnetometer:\nx=${mag?.x.toStringAsFixed(4) ?? 'N/A'}, y=${mag?.y.toStringAsFixed(4) ?? 'N/A'}, z=${mag?.z.toStringAsFixed(4) ?? 'N/A'}',
                    ),
                    const SizedBox(height: 16),
                    Text('最後輸出： ${_lastSavedPath ?? "尚未產生"}'),
                  ],
                ),
              ),
            ),

            // const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

/*
pubspec.yaml 相關相依（加入到你的專案 pubspec.yaml）：

dependencies:
  flutter:
    sdk: flutter
  sensors_plus: ^3.0.0
  path_provider: ^2.0.15
  share_plus: ^6.0.5

（版本號可能會隨時間更新，請以 pub.dev 為準）

Android 注意（選用）：
- 若你想直接將檔案放到公開 Downloads 資料夾，需要處理 Android 的檔案寫入權限（READ/WRITE_EXTERNAL_STORAGE），以及在 Android 11+ 要使用 MediaStore 或 SAF。
- 這個範例把檔案放在 App 的 files 目錄（不需要額外權限），並用系統分享介面分享該檔案。

*/
