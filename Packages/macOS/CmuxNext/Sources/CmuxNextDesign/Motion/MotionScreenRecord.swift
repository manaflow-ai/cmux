#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import AVFoundation
import CmuxNextCompat
import CmuxNextWakeups
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// `debug.motion` `record_*` (DEBUG and `CMUX_BENCH_HOOKS` builds): every frame the window server composites
/// for one of this app's windows, at the display's rate, as a movie, so motion is judged from what a person sees
/// (the resize-videos kit, handoff resize-videos/KIT.md). ScreenCaptureKit with `SCShareableContent.currentProcess`
/// (macOS 14.4 and later): an app may capture its own windows without the Screen Recording grant. Unlike
/// `debug.window_record`, which takes a snapshot on the main thread each frame and so slows what it records, this
/// adds no main-thread work per frame: ScreenCaptureKit and the encoder call back on a queue of their own.
///
/// After `record_`:
/// - `start` {`path` (the movie, .mov), `window` (an index into `windows`, default 0, as `trace_start`),
///   `codec` (`hevc`, the default, or `prores`: ProRes 4444), `mbps` (the HEVC bit rate, default 300),
///   `seconds` (default 30, at most 120: the recording ends by itself then), `rows` and `columns` (device-pixel
///   rows and columns of the frame kept exact for every frame; default a quarter, half and three quarters of the
///   window), `filter` (`display`, the default, or `window`)}. Replies at once; the capture starts on the next
///   turns: `read` says `capturing` once it runs, or `error`. The frame starts at the window's top-left corner and
///   runs to its screen's right and bottom edges, in device pixels, 1:1 (a window resize is never scaled).
///   `display`: the window's screen showing only this app's windows (`SCContentFilter(display:including:)` with
///   the app's on-screen windows, cropped by `sourceRect`): every composited change of those windows makes a frame.
///   `window`: `SCContentFilter(desktopIndependentWindow:)`, transparent past the window. On the minis (macOS 26/27,
///   2026-11-02, probe rounds on cmux24 and cmux22) a window filter on cmux's main window gave frames only when a
///   page child window changed, none for terminal output, a split or a workspace switch.
/// - `stop`: ends the capture; the files are written on the recording's queue: `read` says `written` once they are.
///   Beside the movie: `PATH.frames.json` (every frame ScreenCaptureKit gave as `[t, status, in movie]`: `t` its
///   display time in host seconds, CACurrentMediaTime's clock; `status` ScreenCaptureKit's frame status, `idle`
///   when nothing changed on screen; `in movie` false when the encoder was not ready) and `PATH.scan` (a JSON
///   header line, then for each complete frame its host time as a little-endian Float64 and each kept row, then
///   each kept column, as BGRA).
/// - `read`: the counts of the running recording, else of the last one.
final class MotionScreenRecord {
    private var recording: ScreenRecording?
    private var last: ScreenRecording?
    private var lastError: String?

    func handle(_ action: String, _ params: [String: Any], windows: [NSWindow]) -> [String: Any] {
        switch action {
        case "start":
            return start(params, windows: windows)
        case "stop":
            guard let recording else { return ["error": "no recording"] }
            self.recording = nil
            recording.finish()
            return recording.counts()
        default:
            var counts = (recording ?? last)?.counts() ?? ["capturing": false]
            if let lastError { counts["error"] = lastError }
            return counts
        }
    }

    private func start(_ params: [String: Any], windows: [NSWindow]) -> [String: Any] {
        guard recording == nil else { return ["error": "a recording is running"] }
        let index = params["window"] as? Int ?? 0
        guard windows.indices.contains(index) else { return ["error": "no such window"] }
        let window = windows[index]
        guard let path = (params["path"] as? String).map({ ($0 as NSString).expandingTildeInPath }) else {
            return ["error": "path is required"]
        }
        let scale = window.backingScaleFactor
        let screenFrame = (window.screen ?? NSScreen.main)?.frame ?? window.frame
        // The window's top-left corner on its screen, in points from the screen's top-left: the frame's origin.
        let left = max(0, window.frame.minX - screenFrame.minX), top = max(0, screenFrame.maxY - window.frame.maxY)
        let source = CGRect(x: left, y: top, width: max(window.frame.width, screenFrame.width - left),
                            height: max(window.frame.height, screenFrame.height - top))
        let width = Int((source.width * scale).rounded()) / 2 * 2
        let height = Int((source.height * scale).rounded()) / 2 * 2
        let display = (window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let useDisplay = (params["filter"] as? String ?? "display") == "display"
        let windowWidth = Int((window.frame.width * scale).rounded()), windowHeight = Int((window.frame.height * scale).rounded())
        func lines(_ key: String, _ extent: Int, _ limit: Int) -> [Int] {
            let asked = (params[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
            return (asked ?? [extent / 4, extent / 2, extent * 3 / 4]).map { min(max($0, 0), limit - 1) }
        }
        let options = ScreenRecording.Options(
            url: URL(fileURLWithPath: path), width: width, height: height, prores: params["codec"] as? String == "prores",
            bitsPerSecond: Int(((params["mbps"] as? NSNumber)?.doubleValue ?? 300) * 1_000_000),
            rows: lines("rows", windowHeight, height), columns: lines("columns", windowWidth, width),
            seconds: min(120, max(0.5, (params["seconds"] as? NSNumber)?.doubleValue ?? 30)), scale: Double(scale),
            display: useDisplay ? display.map { CGDirectDisplayID($0) } : nil, sourceRect: source)
        // The main thread only reads the window's facts above. The folder, ScreenCaptureKit's content list, the
        // stream and the writer are made off it (`ScreenRecording.start`): starting a recording must not stall the
        // app it films (the first version spent 48-72 ms of one main-thread turn here, STATUS 4500).
        let recording = ScreenRecording(options)
        self.recording = recording
        last = recording
        lastError = nil
        let windowNumber = CGWindowID(window.windowNumber)
        Task { @MainActor [weak self] in
            do {
                try await recording.start(windowNumber: windowNumber)
            } catch {
                guard let self, self.recording === recording else { return }
                self.recording = nil
                self.lastError = "\(error)"
                recording.finish()
            }
        }
        return ["starting": true, "path": path, "width": width, "height": height, "scale": Double(scale),
                "window": window.windowNumber, "rows": options.rows, "columns": options.columns,
                "filter": useDisplay ? "display" : "window", "display": display.map { Int($0) } ?? -1,
                "source_rect": [source.minX, source.minY, source.width, source.height]]
    }
}

/// One `record_*` recording: ScreenCaptureKit's frames go to an AVAssetWriter and a scanline file, both on
/// `queue`, off the main thread.
// Counts and the stream live in Mutexes. The writer is made on `queue` at the first frame; finish() hops onto `queue`
// to close. start() runs off the main actor (@concurrent): no ScreenCaptureKit or file call runs on the main thread.
// crash-allow: the writer, its input and the scan bytes are not Sendable but are touched on `queue` only (see above).
nonisolated final class ScreenRecording: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    nonisolated struct Options: Sendable {
        let url: URL
        let width: Int
        let height: Int
        let prores: Bool
        let bitsPerSecond: Int
        let rows: [Int]
        let columns: [Int]
        let seconds: Double
        /// The window's backing scale (device pixels per point).
        let scale: Double
        /// The display filter's screen (nil: a window filter).
        let display: CGDirectDisplayID?
        /// The part of the screen recorded, in points from its top-left (the window's top-left onward).
        let sourceRect: CGRect
    }

    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// One frame ScreenCaptureKit gave.
    nonisolated struct Frame: Sendable {
        let time: Double
        let status: String
        let inMovie: Bool
    }

    nonisolated struct State: Sendable {
        var frames: [Frame] = []
        var complete = 0
        var idle = 0
        var notReady = 0
        var firstTime: Double?
        var capturing = false
        /// No frame is taken any more (stop asked).
        var ending = false
        /// The movie and the side files are closed.
        var written = false
        var movieStatus = ""
        var stoppedBy: String?
        /// Sample callbacks of any kind (any at all proves the stream delivers).
        var callbacks = 0
    }

    /// Seconds any one ScreenCaptureKit call may take (a disconnected replayd never answers; the animation pixel
    /// harness hung 180 s on one).
    static let callLimit: Duration = .seconds(10)

    private let options: Options
    private let queue = DispatchQueue(label: "debug.motion.record", qos: .userInitiated)
    /// Made on `queue` at the first complete frame, at that frame's size (the set-up that delivers decides it).
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// The scan file's bytes, written whole at the end (no file handle stays open while frames come).
    private var scan = Data()
    // concurrency-allow: the counts are touched by ScreenCaptureKit's queue and the main actor; each hold copies or
    // appends a value and never waits on I/O, a call out or an await.
    private let state = Mutex(State())
    private let limit = DemandTimer(owner: "debug.motion.record.limit")
    // concurrency-allow: held only to put or take the stream; no ScreenCaptureKit call runs under it.
    private let streamSlot = Mutex<Handed<SCStream>?>(nil)

    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    init(_ options: Options) {
        self.options = options
        super.init()
        let header: [String: Any] = ["width": options.width, "height": options.height, "rows": options.rows,
                                     "columns": options.columns, "format": "BGRA", "time": "float64-le host seconds"]
        scan = ((try? JSONSerialization.data(withJSONObject: header)) ?? Data()) + Data([0x0A])
    }

    /// Off the main actor: the folder, ScreenCaptureKit's content list, the filter, the stream and its start.
    @concurrent nonisolated func start(windowNumber: CGWindowID) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(description: "own-window capture needs macOS 14.4") }
        try FileManager.checked.createDirectory(at: options.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.checked.removeItem(at: options.url)
        let content: Handed<SCShareableContent> = try await deadline("list this process's windows") { done in
            SCShareableContent.getCurrentProcessShareableContent { content, error in
                done(content.map { .success(Handed($0)) } ?? .failure(error ?? Failure(description: "no shareable content")))
            }
        }
        guard let target = content.value.windows.first(where: { $0.windowID == windowNumber }) else {
            throw Failure(description: "ScreenCaptureKit lists no window \(windowNumber) of this process")
        }
        let filter: SCContentFilter
        if let displayID = options.display {
            guard let display = content.value.displays.first(where: { $0.displayID == displayID }) else {
                throw Failure(description: "ScreenCaptureKit lists no display \(displayID) for this process (\(content.value.displays.count) listed)")
            }
            // Every on-screen window of this app on that display: page child windows and panels show as on screen.
            let own = content.value.windows.filter { $0.isOnScreen && $0.frame.intersects(display.frame) }
            filter = SCContentFilter(display: display, including: own.isEmpty ? [target] : own)
        } else {
            filter = SCContentFilter(desktopIndependentWindow: target)
        }
        let stream = SCStream(filter: filter, configuration: configuration(), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let _: Bool = try await deadline("start the capture") { done in
            stream.startCapture { error in done(error.map { .failure($0) } ?? .success(true)) }
        }
        // A stop asked while the stream started: stop it at once.
        guard !state.withLock({ $0.ending }) else {
            _ = try? await deadline("stop the capture") { done in stream.stopCapture { error in done(error.map { .failure($0) } ?? .success(true)) } }
            return
        }
        streamSlot.withLock { $0 = Handed(stream) }
        state.withLock { $0.capturing = true }
        limit.schedule(after: .seconds(options.seconds)) { [weak self] in self?.finish() }
    }

    private nonisolated func configuration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = options.width
        configuration.height = options.height
        if options.display != nil { configuration.sourceRect = options.sourceRect }
        // Faster than any display: ScreenCaptureKit then gives every composited frame.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 8
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        configuration.backgroundColor = CGColor.clear
        configuration.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { configuration.includeChildWindows = true }
        return configuration
    }

    /// Ends the capture once, then closes the movie and the side files on `queue` (`written` in the counts).
    /// Any thread; the stop and the files run off the main actor.
    nonisolated func finish() {
        guard !state.withLock({ state -> Bool in defer { state.ending = true }; return state.ending }) else { return }
        limit.cancel()
        let handed = streamSlot.withLock { slot -> Handed<SCStream>? in defer { slot = nil }; return slot }
        Task.detached(priority: .userInitiated) { [self] in
            if let stream = handed?.value {
                let _: Bool? = try? await deadline("stop the capture") { done in
                    stream.stopCapture { error in done(error.map { .failure($0) } ?? .success(true)) }
                }
            }
            queue.async { [self] in close() }
        }
    }

    /// On `queue`: the side files, then the movie.
    private func close() {
        try? scan.blockingWrite(to: options.url.appendingPathExtension("scan"))
        let snapshot = state.withLock { $0 }
        let frames = snapshot.frames.map { [$0.time, $0.status, $0.inMovie] as [Any] }
        let index: [String: Any] = ["frames": frames, "rows": options.rows, "columns": options.columns,
                                    "width": options.width, "height": options.height]
        if let data = try? JSONSerialization.data(withJSONObject: index) {
            try? data.blockingWrite(to: options.url.appendingPathExtension("frames.json"))
        }
        guard let writer, let input, writer.status == .writing else {
            let status = "not written: \(writer.map { "\($0.status.rawValue) \(String(describing: $0.error))" } ?? "no frame came")"
            state.withLock { $0.written = true; $0.capturing = false; $0.movieStatus = status }
            return
        }
        input.markAsFinished()
        writer.finishWriting { [self] in
            let status = self.writer?.status == .completed ? "completed" : "failed: \(String(describing: self.writer?.error))"
            state.withLock { $0.written = true; $0.capturing = false; $0.movieStatus = status }
        }
    }

    func counts() -> [String: Any] {
        let state = state.withLock { $0 }
        return ["capturing": state.capturing, "written": state.written, "movie_status": state.movieStatus,
                "path": options.url.path, "frames": state.frames.count, "complete": state.complete, "idle": state.idle,
                "encoder_not_ready": state.notReady, "first_t": state.frames.first?.time ?? 0,
                "last_t": state.frames.last?.time ?? 0, "stopped_by": state.stoppedBy ?? "", "callbacks": state.callbacks,
                "filter": options.display == nil ? "window" : "display"]
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        state.withLock { $0.callbacks += 1 }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        let time = Double((info[.displayTime] as? NSNumber)?.uint64Value ?? 0) * Self.secondsPerTick
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            state.withLock { state in
                guard !state.ending else { return }
                state.frames.append(Frame(time: time, status: Self.name(status), inMovie: false))
                if status == .idle { state.idle += 1 }
            }
            return
        }
        let start = state.withLock { state -> (first: Double, isFirst: Bool)? in
            guard !state.ending else { return nil }
            if let first = state.firstTime { return (first, false) }
            state.firstTime = time
            return (time, true)
        }
        guard let start else { return }
        if start.isFirst { openWriter(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) }
        var appended = false
        if let input, let adaptor, input.isReadyForMoreMediaData {
            appended = adaptor.append(buffer, withPresentationTime: CMTime(seconds: time - start.first, preferredTimescale: 1_000_000))
        }
        writeScanlines(buffer, time: time)
        state.withLock { state in
            state.frames.append(Frame(time: time, status: "complete", inMovie: appended))
            state.complete += 1
            if !appended { state.notReady += 1 }
        }
    }

    /// On `queue`, at the first complete frame: the movie writer at that frame's size.
    private func openWriter(width: Int, height: Int) {
        var settings: [String: Any] = [AVVideoWidthKey: width, AVVideoHeightKey: height]
        if options.prores {
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        } else {
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: options.bitsPerSecond, AVVideoExpectedSourceFrameRateKey: 120,
                AVVideoMaxKeyFrameIntervalKey: 120, AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any]
        }
        guard let writer = try? AVAssetWriter(outputURL: options.url, fileType: .mov) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        state.withLock { $0.stoppedBy = String(describing: error) }
    }

    /// The kept rows and columns of one complete frame, exact (BGRA), after its host time.
    private func writeScanlines(_ buffer: CVPixelBuffer, time: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = min(CVPixelBufferGetWidth(buffer), options.width), height = min(CVPixelBufferGetHeight(buffer), options.height)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var record = Data(capacity: 8 + 4 * (options.rows.count * options.width + options.columns.count * options.height))
        withUnsafeBytes(of: time.bitPattern.littleEndian) { record.append(contentsOf: $0) }
        for y in options.rows {
            var line = [UInt32](repeating: 0, count: max(0, options.width))
            if y < height { for x in 0..<width { line[x] = base.load(fromByteOffset: y * stride + x * 4, as: UInt32.self) } }
            line.withUnsafeBytes { record.append(contentsOf: $0) }
        }
        for x in options.columns {
            var line = [UInt32](repeating: 0, count: max(0, options.height))
            if x < width { for y in 0..<height { line[y] = base.load(fromByteOffset: y * stride + x * 4, as: UInt32.self) } }
            line.withUnsafeBytes { record.append(contentsOf: $0) }
        }
        scan.append(record)
    }

    private static func name(_ status: SCFrameStatus) -> String {
        switch status {
        case .complete: "complete"
        case .idle: "idle"
        case .blank: "blank"
        case .suspended: "suspended"
        case .started: "started"
        case .stopped: "stopped"
        @unknown default: "unknown"
        }
    }

    /// Runs `call` with a completion `done` and returns its result, or throws after ``callLimit``. The
    /// continuation resumes once: on the result or the deadline, whichever comes first; a late callback is dropped.
    private nonisolated func deadline<T: Sendable>(_ what: String, limit: Duration = callLimit,
                                       _ call: (@escaping @Sendable (Result<T, any Error>) -> Void) -> Void) async throws -> T {
        let once = Once<T>()
        let timer = DemandTimer(owner: "debug.motion.record.deadline")
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            once.set(continuation)
            call { once.resume($0) }
            timer.schedule(after: limit) {
                once.resume(.failure(Failure(description: "ScreenCaptureKit did not \(what) within \(limit)")))
            }
        }
    }

    /// A ScreenCaptureKit result handed from its callback queue to the main actor once.
    // crash-allow: ScreenCaptureKit makes the value and never touches it again; only the main actor reads it, after the hand-over.
    nonisolated struct Handed<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    /// Resumes a continuation once; later results are dropped.
    private nonisolated final class Once<T: Sendable>: Sendable {
        // concurrency-allow: held only to take or set the continuation; resuming it happens after the unlock.
        private let slot = Mutex<CheckedContinuation<T, any Error>?>(nil)
        func set(_ continuation: CheckedContinuation<T, any Error>) { slot.withLock { $0 = continuation } }
        func resume(_ result: Result<T, any Error>) {
            let pending = slot.withLock { slot -> CheckedContinuation<T, any Error>? in
                defer { slot = nil }
                return slot
            }
            pending?.resume(with: result)
        }
    }
}
#endif
