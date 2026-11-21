// SPDX-License-Identifier: GPL-3.0-or-later
@preconcurrency import CoreGraphics
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit
@preconcurrency import VideoToolbox

/// A live ScreenCaptureKit stream of one window. The window server sends a
/// frame only when the window's pixels change, so the stream answers two
/// questions for free: what the window looks like now (the latest frame, no
/// capture round trip), and whether it is still changing (the time of the
/// last new frame), which is how the engine knows an action has settled.
final class WindowStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let windowID: CGWindowID
    let pid: pid_t
    let pixelWidth: Int
    let pixelHeight: Int
    /// Made after `super.init` so the stream can name this object as its
    /// delegate (a stop by ScreenCaptureKit must mark the stream dead).
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "cmux.cu.window-stream", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestAt: ContinuousClock.Instant?
    private var frames = 0
    private var stopped = false
    /// Every sample's SCFrameStatus raw value, counted (diagnostics).
    private var statusCounts: [Int: Int] = [:]
    private var stopError: String?
    private var usedAt = ContinuousClock.now
    var lastUsed: ContinuousClock.Instant { lock.withLock { usedAt } }

    init(window: SCWindow, pid: pid_t, pixelWidth: Int, pixelHeight: Int) throws {
        windowID = window.windowID
        self.pid = pid
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        let config = SCStreamConfiguration()
        config.width = max(1, pixelWidth)
        config.height = max(1, pixelHeight)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = true
        config.capturesAudio = false
        config.queueDepth = 4
        // Up to 60 frames a second while the window changes; none while it is still.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        super.init()
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
    }

    func start() async throws { try await stream?.startCapture() }

    func stop() {
        let alreadyStopped = lock.withLock { () -> Bool in
            defer { stopped = true }
            return stopped
        }
        guard !alreadyStopped else { return }
        stream?.stopCapture { _ in }
    }

    var isStopped: Bool { lock.withLock { stopped } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let statusRaw = (attachments?.first?[.status] as? NSNumber)?.intValue ?? -1
        lock.withLock { statusCounts[statusRaw, default: 0] += 1 }
        // A complete frame, or the first frame of a still window (which may
        // carry no status), has pixels; idle and blank frames do not.
        guard statusRaw == SCFrameStatus.complete.rawValue || statusRaw == -1,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ContinuousClock.now
        lock.withLock {
            latest = pixels
            latestAt = now
            frames += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock {
            stopped = true
            stopError = "\(error)"
        }
    }

    /// Diagnostics for `cmux-cu-service probe`.
    var diagnostics: String {
        lock.withLock { "frames=\(frames) statuses=\(statusCounts) stopped=\(stopped) error=\(stopError ?? "none")" }
    }

    /// Time of the newest frame (nil before the first one).
    var lastFrameAt: ContinuousClock.Instant? { lock.withLock { latestAt } }
    var frameCount: Int { lock.withLock { frames } }

    /// The newest frame as a CGImage (no capture round trip).
    func image() -> CGImage? {
        let pixels: CVPixelBuffer? = lock.withLock {
            usedAt = .now
            return latest
        }
        guard let pixels else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        return image
    }

    /// Waits for the first frame (a new stream's first frame is the whole
    /// window), bounded by `timeout`.
    func firstFrame(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if lastFrameAt != nil { return true }
            try? await Task.sleep(for: .milliseconds(2), tolerance: .milliseconds(1), clock: clock)
        }
        return lastFrameAt != nil
    }
}

/// When an action has settled, judged on the window's pixels and the app's
/// accessibility notifications together:
///   - the window drew a new frame after the action and then drew nothing for
///     `visualQuiet`, or drew nothing at all for `visualIdle` (no visible change);
///   - and the app sent no accessibility notification for `axQuiet`;
///   - or `ceiling` passed (an app that never stops animating).
struct VisualSettlePolicy: Sendable, Equatable {
    var visualQuiet: Duration = .milliseconds(48)
    var visualIdle: Duration = .milliseconds(100)
    var axQuiet: Duration = .milliseconds(32)
    var ceiling: Duration = .milliseconds(800)

    func outcome(elapsed: Duration, sinceFrame: Duration?, sinceAX: Duration?) -> SettleOutcome? {
        if elapsed >= ceiling { return .ceiling }
        if let sinceAX, sinceAX < axQuiet { return nil }
        if let sinceFrame { return sinceFrame >= visualQuiet ? .quiet : nil }
        return elapsed >= visualIdle ? .idle : nil
    }
}

/// One stream per recently used window, started on first use and stopped
/// when it has not been asked for in `idleStop`.
final class WindowStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [CGWindowID: WindowStream] = [:]
    private var shareable: [CGWindowID: SCWindow] = [:]
    let idleStop: Duration = .seconds(90)

    /// The window's stream at this pixel size, started (and given its first
    /// frame) when needed. Nil when the window cannot be streamed (off
    /// screen, minimized, no grant): the caller falls back to a screenshot.
    private var failure: String?
    var lastFailure: String? { lock.withLock { failure } }
    /// Windows whose stream gave no frame: a screenshot is taken instead,
    /// without paying the first-frame wait again for `failureBackoff`.
    private var failedAt: [CGWindowID: ContinuousClock.Instant] = [:]
    let failureBackoff: Duration = .seconds(30)

    func stream(windowID: CGWindowID, pid: pid_t, pixelWidth: Int, pixelHeight: Int,
                firstFrameTimeout: Duration = .milliseconds(250)) async -> WindowStream? {
        if let failed = lock.withLock({ failedAt[windowID] }), ContinuousClock.now - failed < failureBackoff {
            return nil
        }
        reap()
        if let existing = lock.withLock({ streams[windowID] }), !existing.isStopped,
           existing.pixelWidth == pixelWidth, existing.pixelHeight == pixelHeight {
            return existing
        }
        if let old = lock.withLock({ streams.removeValue(forKey: windowID) }) { old.stop() }
        guard let window = await scWindow(windowID) else { return fail(windowID, "window not shareable") }
        let stream: WindowStream
        do {
            stream = try WindowStream(window: window, pid: pid, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            try await stream.start()
        } catch {
            return fail(windowID, "start: \(error)")
        }
        guard await stream.firstFrame(timeout: firstFrameTimeout) else {
            let why = stream.diagnostics
            stream.stop()
            return fail(windowID, "no frame: \(why)")
        }
        // Two callers may have raced to start this window's stream: the one
        // stored last wins, and the one it displaces is stopped, never leaked.
        let displaced = lock.withLock { () -> WindowStream? in
            defer { streams[windowID] = stream }
            return streams[windowID]
        }
        if let displaced, displaced !== stream { displaced.stop() }
        return stream
    }

    private func fail(_ id: CGWindowID, _ why: String) -> WindowStream? {
        lock.withLock {
            failedAt[id] = .now
            failure = why
        }
        return nil
    }

    /// Stops every stream of an app that exited.
    func stop(pid: pid_t) {
        let gone = lock.withLock { () -> [WindowStream] in
            let matching = streams.filter { $0.value.pid == pid }
            for id in matching.keys { streams[id] = nil }
            return Array(matching.values)
        }
        for stream in gone { stream.stop() }
    }

    func existing(windowID: CGWindowID) -> WindowStream? {
        lock.withLock { streams[windowID].flatMap { $0.isStopped ? nil : $0 } }
    }

    private func scWindow(_ id: CGWindowID) async -> SCWindow? {
        if let cached = lock.withLock({ shareable[id] }) { return cached }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return nil
        }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        lock.withLock { shareable = byID }
        return byID[id]
    }

    private func reap() {
        let now = ContinuousClock.now
        let idle = lock.withLock { () -> [WindowStream] in
            let gone = streams.filter { now - $0.value.lastUsed > idleStop || $0.value.isStopped }
            for id in gone.keys { streams[id] = nil }
            return Array(gone.values)
        }
        for stream in idle { stream.stop() }
    }
}
