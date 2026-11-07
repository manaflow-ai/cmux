import AppKit
import AVFoundation
import CmuxNextCompat
import CmuxNextWakeups
import CoreMedia
import os
import ScreenCaptureKit

/// The capture bar's Record (plans/cmux-next/capture-bar-DESIGN.md): `capture.record.start` films
/// the cmux window that hosts the pane, `capture.record.stop` ends it and answers the movie. The
/// frames come from ScreenCaptureKit's current-process content (macOS 14.4 and later), which needs
/// no Screen Recording grant, and go to an H.264 `.mp4` in the temporary folder
/// (``folder``). One recording at a time in the app. It stops by itself
/// after ``maxSeconds``, when its window closes and when the app quits; every end releases the
/// stream and the writer. Nothing runs on the main thread per frame.
@MainActor
final class AgentPaneRecorder {
    static let shared = AgentPaneRecorder()
    /// A recording stops by itself after this long (the design's `maxSeconds`).
    nonisolated static let maxSeconds = 300
    /// At most this many frames a second.
    nonisolated static let framesPerSecond: Int32 = 60
    /// The movie's longest side, in pixels.
    nonisolated static let maxSide = 2560
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.record")

    /// Where recordings go: one folder per recording, so its file keeps the plain name. A
    /// recording that is never attached goes with the temporary folder.
    nonisolated static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-capture", isDirectory: true)

    private var current: AgentPaneRecording?
    private var starting = false
    private var observers: [any NSObjectProtocol] = []
    /// The movies this process wrote, exactly as the page was given them (realpath's spelling):
    /// the only paths `capture.copy` and `capture.save` take.
    private(set) var written: Set<String> = []
    /// Whether the capture bar's save panel is up: one at a time.
    var saving = false

    /// Starts filming `window`: `{started: true}`, `capture.busy` while one runs, `capture.failed`
    /// when ScreenCaptureKit could not start (no window, macOS before 14.4).
    func start(in window: NSWindow, cursor: Bool, clicks: Bool) async -> [String: Any] {
        guard !starting, current?.isEnding != false else {
            return AgentPaneReply.failure(code: "capture.busy", message: AgentPaneModel.captureFailedMessage)
        }
        // One that ended by itself (its window closed, the limit) and was never stopped: its movie
        // was never handed out, so it goes.
        if let stale = current {
            current = nil
            Task.detached(priority: .utility) { await stale.discard() }
        }
        removeObservers()
        guard window.windowNumber > 0, window.isVisible, !window.isMiniaturized else {
            return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
        }
        let folder = Self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recording = AgentPaneRecording(AgentPaneRecording.Options(
            window: CGWindowID(window.windowNumber), scale: Double(window.backingScaleFactor), cursor: cursor, clicks: clicks,
            url: folder.appendingPathComponent(Self.name(Date()))))
        starting = true
        defer { starting = false }
        do {
            try await recording.start()
        } catch {
            Self.logger.error("capture.record.start failed: \(String(describing: error), privacy: .public)")
            Task.detached(priority: .utility) { await recording.discard() }
            return AgentPaneReply.failure(code: "capture.failed", message: AgentPaneModel.captureFailedMessage)
        }
        current = recording
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in recording.end() },
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in recording.end() },
        ]
        // The window closed while ScreenCaptureKit started: no close notice comes any more.
        if !window.isVisible { recording.end() }
        return AgentPaneReply.success(["started": true])
    }

    /// Ends the recording and answers `{path, name, seconds}`, or `{cancelled: true}` when none
    /// runs or it has no frame (its folder is removed then).
    func stop() async -> [String: Any] {
        guard let recording = current else { return AgentPaneReply.success(["cancelled": true]) }
        current = nil
        removeObservers()
        guard let made = await recording.finish() else { return AgentPaneReply.success(["cancelled": true]) }
        written.insert(made.path)
        return AgentPaneReply.success(["path": made.path, "name": made.name, "seconds": made.seconds])
    }

    /// The file at `path` when this bridge wrote it; nil otherwise.
    func owned(_ path: String) -> URL? { Self.owned(path, in: Self.folder, written: written) }

    /// Pure: `path` as a file URL when it is absolute, has no empty, `.` or `..` part, lies under
    /// `folder` (as spelled, or under `/private` as realpath spells `/var` and `/tmp`) and is
    /// exactly one of `written`.
    nonisolated static func owned(_ path: String, in folder: URL, written: Set<String>) -> URL? {
        guard path.hasPrefix("/"), !path.utf8.contains(0), written.contains(path) else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        guard path.hasPrefix(root) || path.hasPrefix("/private" + root) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    /// The movie's name, as macOS names its own: "Recording 2026-11-07 14.32.05.mp4".
    nonisolated static func name(_ date: Date) -> String { "Recording \(AgentPaneCapture.stamp(date)).mp4" }

    /// The movie's pixel size for `points` at `scale`: the backing size, scaled down to
    /// ``maxSide`` on its longest side, each side even (H.264) and at least 2.
    nonisolated static func size(points: CGSize, scale: Double) -> (width: Int, height: Int) {
        let width = Double(points.width) * scale, height = Double(points.height) * scale
        let fit = min(1, Double(maxSide) / max(width, height, 1))
        func even(_ side: Double) -> Int { max(2, Int((side * fit).rounded(.down)) / 2 * 2) }
        return (even(width), even(height))
    }
}

/// One recording: ScreenCaptureKit's stream of the window's display, showing only this app's
/// windows and cut to the window, into an AVAssetWriter. The stream's frames and the writer run on
/// `queue`; start and the end run off the main actor, each ScreenCaptureKit call under a deadline.
// crash-allow: `writer`, `input`, `adaptor` and `writerFailed` are touched only on `queue` (frames and the close, which hops onto it); the rest is in Mutexes.
nonisolated final class AgentPaneRecording: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    nonisolated struct Options: Sendable {
        let window: CGWindowID
        let scale: Double
        let cursor: Bool
        let clicks: Bool
        let url: URL
    }

    /// The finished movie, as the page gets it.
    nonisolated struct Made: Sendable {
        let path: String
        let name: String
        let seconds: Double
    }

    nonisolated struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private nonisolated struct State: Sendable {
        var ending = false
        var first: CMTime?
        var last: CMTime?
    }

    /// Seconds any one ScreenCaptureKit call may take (a disconnected replayd never answers).
    static let callLimit: Duration = .seconds(10)

    private let options: Options
    private let queue = DispatchQueue(label: "agent-pane.capture.record", qos: .userInitiated)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// The writer could not open: no frame tries again, and the stop answers cancelled.
    private var writerFailed = false
    // concurrency-allow: held only to read or set the flags and times; no call out or I/O runs under it.
    private let state = Mutex(State())
    // concurrency-allow: held only to put or take the stream; no ScreenCaptureKit call runs under it.
    private let streamSlot = Mutex<Handed<SCStream>?>(nil)
    // concurrency-allow: held only to make or read the one end task; the task runs after the unlock.
    private let outcome = Mutex<Task<Made?, Never>?>(nil)
    private let limit = DemandTimer(owner: "agent-pane.capture.record.limit")

    init(_ options: Options) {
        self.options = options
        super.init()
    }

    var isEnding: Bool { state.withLock { $0.ending } }

    /// The folder, ScreenCaptureKit's content list, the filter and the stream's start, off the main actor.
    @concurrent func start() async throws {
        guard #available(macOS 14.4, *) else { throw Failure(description: "own-window capture needs macOS 14.4") }
        try FileManager.checked.createDirectory(at: options.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content: Handed<SCShareableContent> = try await deadline("list this process's windows") { done in
            SCShareableContent.getCurrentProcessShareableContent { content, error in
                done(content.map { .success(Handed($0)) } ?? .failure(error ?? Failure(description: "no shareable content")))
            }
        }
        guard let target = content.value.windows.first(where: { $0.windowID == options.window }) else {
            throw Failure(description: "ScreenCaptureKit lists no window \(options.window) of this process")
        }
        guard let display = content.value.displays.first(where: { $0.frame.intersects(target.frame) }) ?? content.value.displays.first else {
            throw Failure(description: "ScreenCaptureKit lists no display for this process")
        }
        // The display with only this app's on-screen windows, cut to the window: its page child
        // windows and panels show as on screen (a window filter misses changes outside them).
        let own = content.value.windows.filter { $0.isOnScreen && $0.frame.intersects(display.frame) }
        let filter = SCContentFilter(display: display, including: own.isEmpty ? [target] : own)
        let source = target.frame.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        guard source.width >= 1, source.height >= 1 else { throw Failure(description: "the window is off its display") }
        let stream = SCStream(filter: filter, configuration: configuration(source), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let _: Bool = try await deadline("start the capture") { done in
            stream.startCapture { error in done(error.map { .failure($0) } ?? .success(true)) }
        }
        // Store first, then look at `ending`: an end in between found no stream, so this side
        // stops it; an end after the store stops it itself. Exactly one side stops the stream.
        streamSlot.withLock { $0 = Handed(stream) }
        if isEnding, let mine = streamSlot.withLock({ slot -> Handed<SCStream>? in defer { slot = nil }; return slot }) {
            _ = try? await stop(mine.value)
            return
        }
        limit.schedule(after: .seconds(AgentPaneRecorder.maxSeconds)) { [weak self] in self?.end() }
    }

    private func configuration(_ source: CGRect) -> SCStreamConfiguration {
        let size = AgentPaneRecorder.size(points: source.size, scale: options.scale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = source
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: AgentPaneRecorder.framesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 6
        configuration.showsCursor = options.cursor
        if #available(macOS 15.0, *) { configuration.showMouseClicks = options.clicks }
        return configuration
    }

    /// Ends the recording once (any thread, at once); ``finish()`` waits for the movie.
    func end() { _ = ending() }

    /// Ends the recording once and returns its movie, nil when it has no frame or did not write.
    func finish() async -> Made? { await ending().value }

    /// Ends it and removes its folder: a movie nobody was given.
    func discard() async {
        _ = await finish()
        try? FileManager.checked.removeItem(at: options.url.deletingLastPathComponent())
    }

    private func ending() -> Task<Made?, Never> {
        outcome.withLock { slot in
            if let task = slot { return task }
            state.withLock { $0.ending = true }
            let task = Task.detached(priority: .userInitiated) { [self] in await close() }
            slot = task
            return task
        }
    }

    /// Stops the stream, then closes the movie on `queue`; a recording with no movie leaves no folder.
    private func close() async -> Made? {
        limit.cancel()
        if let handed = streamSlot.withLock({ slot -> Handed<SCStream>? in defer { slot = nil }; return slot }) {
            _ = try? await stop(handed.value)
        }
        let stoppedAt = CMClockGetTime(CMClockGetHostTimeClock())
        let made = await withCheckedContinuation { (done: CheckedContinuation<Made?, Never>) in
            queue.async { [self] in closeMovie(at: stoppedAt) { done.resume(returning: $0) } }
        }
        if made == nil { try? FileManager.checked.removeItem(at: options.url.deletingLastPathComponent()) }
        return made
    }

    /// On `queue`: the movie's end, at the stop when nothing changed on screen since the last frame.
    private func closeMovie(at stoppedAt: CMTime, _ done: @escaping @Sendable (Made?) -> Void) {
        let times = state.withLock { $0 }
        guard let writer, let input, writer.status == .writing, let first = times.first, let last = times.last else {
            if writer?.status == .writing { writer?.cancelWriting() }
            return done(nil)
        }
        let cap = CMTimeAdd(first, CMTime(value: CMTimeValue(AgentPaneRecorder.maxSeconds + 1), timescale: 1))
        let end = CMTimeMinimum(CMTimeMaximum(last, stoppedAt), cap)
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        let url = options.url
        let seconds = (CMTimeSubtract(end, first).seconds * 10).rounded() / 10
        writer.finishWriting { [self] in
            guard self.writer?.status == .completed else { return done(nil) }
            let path = AcpmuxPathPolicy.canonical(url.path) ?? url.path
            done(Made(path: path, name: url.lastPathComponent, seconds: seconds))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), !isEnding else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil, !writerFailed { openWriter(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), at: time) }
        guard let input, let adaptor, input.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: time) else { return }
        state.withLock { state in
            if state.first == nil { state.first = time }
            state.last = time
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) { end() }

    /// On `queue`, at the first frame: the H.264 writer at that frame's size, its session from that frame.
    private func openWriter(width: Int, height: Int, at time: CMTime) {
        writerFailed = true
        guard let writer = try? AVAssetWriter(outputURL: options.url, fileType: .mp4) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(24_000_000, max(6_000_000, width * height * 5)),
                AVVideoExpectedSourceFrameRateKey: AgentPaneRecorder.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: Int(AgentPaneRecorder.framesPerSecond) * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        // The adaptor must exist before startWriting (AVFoundation raises for one made after).
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: time)
        (self.writer, self.input, self.adaptor, writerFailed) = (writer, input, adaptor, false)
    }

    private func stop(_ stream: SCStream) async throws {
        let _: Bool = try await deadline("stop the capture") { done in
            stream.stopCapture { error in done(error.map { .failure($0) } ?? .success(true)) }
        }
    }

    /// Runs `call` and returns its result, or throws after ``callLimit``; a late callback is dropped.
    private func deadline<T: Sendable>(_ what: String, _ call: (@escaping @Sendable (Result<T, any Error>) -> Void) -> Void) async throws -> T {
        let once = Once<T>()
        let timer = DemandTimer(owner: "agent-pane.capture.record.deadline")
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            once.set(continuation)
            call { once.resume($0) }
            timer.schedule(after: Self.callLimit) {
                once.resume(.failure(Failure(description: "ScreenCaptureKit did not \(what) within \(Self.callLimit)")))
            }
        }
    }

    /// A ScreenCaptureKit object handed across its callback queue once.
    // crash-allow: ScreenCaptureKit makes the value and never touches it again; one side reads it after the hand-over.
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
