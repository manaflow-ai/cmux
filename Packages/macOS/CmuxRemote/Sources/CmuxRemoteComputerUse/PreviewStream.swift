// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxRemoteWire
import CoreMedia
import CoreVideo
import Foundation
import os
@preconcurrency import ScreenCaptureKit
import VideoToolbox

private let logger = Logger(subsystem: "com.cmuxterm.remote", category: "computer-use-preview")

/// What one look at an agent's window decides for its stream (pure: tests cover each step).
enum PreviewStreamStep: Equatable, Sendable {
    /// Start streaming this window.
    case start(UInt32)
    /// The agent works in another window now: stream that one.
    case restart(UInt32)
    /// Keep the stream as it is.
    case keep
    /// Stop (or do not start), and tell the app why.
    case stop(ComputerUsePreview.Refusal)

    /// The step from the window streamed now and what the privacy gate says of the session's window.
    static func next(streaming current: UInt32?, gate: Result<UInt32, ComputerUsePreview.Refusal>) -> PreviewStreamStep {
        switch (current, gate) {
        case (nil, .success(let window)): .start(window)
        case (let current?, .success(let window)): current == window ? .keep : .restart(window)
        case (_, .failure(let refusal)): .stop(refusal)
        }
    }

    /// The app's status for a refusal: blocked drops any picture; the rest keep the last one, paused.
    static func state(for refusal: ComputerUsePreview.Refusal) -> String {
        switch refusal {
        case .blocked: "blocked"
        case .noWindow: "no_window"
        case .captureFailed, .permission: "paused"
        }
    }
}

/// The encoded frames waiting for a preview's channel (pure: tests cover it).
struct PreviewFrameBacklog: Equatable, Sendable {
    /// Frames handed to the writer and not yet written.
    var pending = 0
    /// Frames are dropped until the next keyframe.
    var dropping = false
    /// The encoder should make its next frame a keyframe (``takeKeyframeRequest()`` clears it).
    var wantsKeyframe = false

    /// Whether an encoded frame goes to the writer (counted as pending) or is dropped. Past `limit`
    /// pending frames the stream drops every frame until a keyframe that fits, and asks the encoder
    /// for one (again if that keyframe had to be dropped too).
    mutating func admit(keyframe: Bool, limit: Int) -> Bool {
        if keyframe, pending < limit { dropping = false }
        if !dropping, pending >= limit {
            dropping = true
            wantsKeyframe = true
        }
        if dropping {
            if keyframe { wantsKeyframe = true }
            return false
        }
        pending += 1
        return true
    }

    /// Whether the encoder should force a keyframe now; the request is taken.
    mutating func takeKeyframeRequest() -> Bool {
        defer { wantsKeyframe = false }
        return wantsKeyframe
    }
}

/// The worker's preview socket: the host splices the app's `computer-use-preview` channel here.
/// Only the host (this worker's parent) may connect; each connection streams one session.
final class PreviewStreamServer: Sendable {
    private let path: String
    private let windowOf: @Sendable (String) -> ComputerUsePreview.SessionWindow?
    private let blocked: @Sendable (String, String) -> Bool

    /// - Parameters:
    ///   - windowOf: The window a session works in (``ComputerUseActivityReporter/window(of:)``).
    ///   - blocked: Whether an app (bundle id, name) is protected, denied or answered Never, now.
    init(path: String, windowOf: @escaping @Sendable (String) -> ComputerUsePreview.SessionWindow?,
         blocked: @escaping @Sendable (String, String) -> Bool) {
        self.path = path
        self.windowOf = windowOf
        self.blocked = blocked
    }

    func start() throws {
        let listener = try LocalSocket.listen(path)
        let parent = getppid()
        LocalSocket.serve(listener, name: "remote-cu-preview") { [windowOf, blocked] channel in
            // The host splices the app's checked channel in; nothing else talks to this socket.
            guard channel.peer?.pid == parent else { return channel.close() }
            guard let request = PreviewStreamWire.Request(channel.readObject()) else { return channel.close() }
            PreviewStreamSession(channel: channel, request: request, windowOf: windowOf, blocked: blocked).run()
        }
    }
}

/// What a preview session reads from the system: the owner and bounds of a window, the
/// ScreenCaptureKit window to stream, and a still. Tests pass their own.
struct PreviewCapture: Sendable {
    var owner: @Sendable (UInt32) -> ComputerUseActivity.App?
    var bounds: @Sendable (UInt32) -> CGRect?
    var window: @Sendable (UInt32) async throws -> SCWindow
    var still: @Sendable (UInt32, Int) async -> Result<(jpeg: Data, width: Int, height: Int), ComputerUsePreview.Refusal>

    static let live = PreviewCapture(
        owner: { ComputerUseActivityReporter.owner(ofWindow: $0) },
        bounds: { ScreenCapture.currentBounds(of: $0) },
        window: { id in
            let content: SCShareableContent
            if let cached = ScreenCapture.reusableContent(holding: id) {
                content = cached
            } else {
                content = try await ScreenCapture.freshContent()
            }
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw ScreenCapture.Failure.noWindow(id) }
            return window
        },
        still: { id, side in await ComputerUsePreview.still(window: id, longSide: side) })
}

/// A preview session's pace. Tests shorten it.
struct PreviewTiming: Sendable {
    /// How often the session's window and its owner are looked at again.
    var look: DispatchTimeInterval = .milliseconds(500)
    /// The least time between two stills.
    var still: TimeInterval = 0.5
    /// The wait before a failed stream start is tried again, doubling up to ``retryMax``.
    var retryBase: TimeInterval = 2
    var retryMax: TimeInterval = 30
    /// The least time between two keyframes the app or the backlog asked for.
    var keyframeGap: TimeInterval = 0.3
}

/// When the encoder makes a keyframe (pure: tests cover it): always at a stream's start or after
/// a new encoder, and when the app or the backlog asks, at most once per `gap`.
struct PreviewKeyframePolicy: Equatable, Sendable {
    var gap: TimeInterval
    /// A new stream or encoder: the next frame is a keyframe whatever the gap.
    var required = true
    /// The app (`K`) or the backlog asked for one.
    var asked = false
    var lastForced: Date?

    /// Whether the frame encoded at `now` is forced to be a keyframe; a forced one clears the asks.
    mutating func force(now: Date) -> Bool {
        let due = required || (asked && lastForced.map { now.timeIntervalSince($0) >= gap } ?? true)
        guard due else { return false }
        required = false
        asked = false
        lastForced = now
        return true
    }
}

/// One app connection: streams the window `request.session` works in, re-checking the window and
/// its app's privacy every half second and its app's privacy on each frame, until the app closes it.
final class PreviewStreamSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable { // crash-allow: mutable state lives on `queue` only
    /// The stream's highest frame rate.
    static let framesPerSecond: Int32 = 30
    /// The most encoded frames waiting for the channel; past it frames are dropped until a keyframe.
    static let maximumPendingFrames = 3
    /// The share a window's pixel size may change by before the stream follows it.
    static let resizeThreshold = 0.03

    private let channel: LineChannel
    private let request: PreviewStreamWire.Request
    private let windowOf: @Sendable (String) -> ComputerUsePreview.SessionWindow?
    private let blocked: @Sendable (String, String) -> Bool
    private let capture: PreviewCapture
    private let timing: PreviewTiming
    private let queue = DispatchQueue(label: "remote-cu-preview.session")
    private let writes = DispatchQueue(label: "remote-cu-preview.write")
    private let closed = DispatchSemaphore(value: 0)
    /// Frames handed to `writes` and not yet written, and whether frames are being dropped until the
    /// next keyframe (the app is reading slower than the stream). VideoToolbox's thread and `writes`.
    private let backlog = OSAllocatedUnfairLock(initialState: PreviewFrameBacklog())
    /// ``ended``, readable off `queue` (a still checks it before it captures).
    private let isEnded = OSAllocatedUnfairLock(initialState: false)

    // `queue` only.
    private var window: UInt32?
    private var owner: ComputerUseActivity.App?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var size = (width: 0, height: 0)
    /// Pixels per point of the streamed window (its filter's scale).
    private var pointScale = 2.0
    /// The picture's long side the app asked for (its request, then `L` lines).
    private var longSide: Int
    private var keyframes: PreviewKeyframePolicy
    private var lastState = ""
    private var ended = false
    private var timer: (any DispatchSourceTimer)?
    private var stillAt: Date?
    /// A still is being captured: never a second one (a slow capture must not pile up).
    private var stillInFlight = false
    /// The stream start in flight (its token), so a late result of an older start is ignored.
    private var startToken = 0
    private var starting = false
    /// Failed starts of this window's stream, and when the next try is due.
    private var startFailures = 0
    private var nextStartAt: Date?
    /// No encoder could be made: stills only, for this session.
    private var encoderUnavailable = false
    /// Counts the windows this session streamed; each `streaming` status names it (`window`), so the
    /// app clears another window's last frame before this one's first arrives.
    private var generation = 0
    private var generationWindow: UInt32?
    /// A size change of the running stream is in flight.
    private var reconfiguring = false

    init(channel: LineChannel, request: PreviewStreamWire.Request,
         windowOf: @escaping @Sendable (String) -> ComputerUsePreview.SessionWindow?,
         blocked: @escaping @Sendable (String, String) -> Bool,
         capture: PreviewCapture = .live, timing: PreviewTiming = PreviewTiming()) {
        self.channel = channel
        self.request = request
        self.windowOf = windowOf
        self.blocked = blocked
        self.capture = capture
        self.timing = timing
        longSide = request.longSide
        keyframes = PreviewKeyframePolicy(gap: timing.keyframeGap)
    }

    /// Streams until the app closes the channel (this connection's own thread waits).
    func run() {
        queue.async { self.look() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timing.look, repeating: timing.look)
        timer.setEventHandler { [weak self] in self?.look() }
        queue.sync { self.timer = timer }
        timer.resume()
        // The app sends only `K` (a keyframe) and `L <side>` (a picture size) lines after its
        // request; a read ends when it closes the channel or ``end()`` shuts it down. This thread is
        // the only one that closes the channel, after its last read and after the writes queued on
        // `writes` ran (to a shut-down socket, so they fail; a still being captured never holds
        // `writes`): a write can never reach the descriptor number once another connection reuses it.
        let reader = Thread { [weak self] in
            guard let self else { return }
            while let line = channel.readLine() {
                if line == PreviewStreamWire.keyframeRequest {
                    queue.async { self.keyframes.asked = true }
                } else if let side = PreviewStreamWire.longSide(line) {
                    queue.async { self.setLongSide(side) }
                }
            }
            end()
            queue.sync {} // end() ran: the encoder's last frames are queued on `writes`
            writes.sync {} // and written (or refused)
            channel.close()
            closed.signal()
        }
        reader.name = "remote-cu-preview-read"
        reader.start()
        closed.wait()
    }

    /// Ends the session: no more looks or stills, the stream stops, and the channel shuts down,
    /// which ends the reader thread; that thread closes it.
    private func end() {
        isEnded.withLock { $0 = true }
        queue.async {
            guard !self.ended else { return }
            self.ended = true
            self.timer?.cancel()
            self.stopStream()
            self.channel.shutdown()
        }
    }

    // MARK: Looking at the window (queue)

    private func look() {
        guard !ended else { return }
        let place = windowOf(request.session)
        let owner = place.flatMap { capture.owner($0.window) }
        let gate = ComputerUsePreview.gate(window: place, owner: owner, blocked: blocked)
        if case .success = gate { self.owner = owner }
        switch PreviewStreamStep.next(streaming: window, gate: gate) {
        case .keep:
            if stream == nil {
                retryStreamIfDue()
                sendStill() // no stream (yet): a still now and then
            } else {
                followWindowSize()
            }
        case .start(let id), .restart(let id):
            stopStream()
            startFailures = 0
            nextStartAt = nil
            startStream(id)
        case .stop(let refusal):
            stopStream()
            send(state: PreviewStreamStep.state(for: refusal))
        }
    }

    private func send(state: String, extra: [String: Any] = [:]) {
        guard state != lastState || !extra.isEmpty else { return }
        lastState = state
        var fields: [String: Any] = ["state": state]
        for (key, value) in extra { fields[key] = value }
        if state == "streaming" || state == "still", let owner {
            var app: [String: Any] = [:]
            if let id = owner.id { app["id"] = id }
            if let name = owner.name { app["name"] = name }
            fields["app"] = app
        }
        write(PreviewStreamWire.status(fields))
    }

    private func write(_ data: Data) {
        writes.async { [weak self] in
            guard let self else { return }
            if !channel.write(data) { end() }
        }
    }

    // MARK: Stream (queue)

    private func startStream(_ id: UInt32) {
        window = id
        startToken += 1
        starting = true
        keyframes.required = true
        let token = startToken, side = longSide, capture = capture
        // task-owner: one stream start for this session; it reports back on `queue`. It holds the
        // session only between its awaits, so a session that ended is not kept alive by a slow start.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let scWindow = try await capture.window(id)
                guard let made = try self?.makeStream(for: scWindow, longSide: side) else { return }
                try await made.stream.startCapture()
                guard let self else {
                    try? await made.stream.stopCapture()
                    return
                }
                queue.async { self.streamStarted(made.stream, id: id, token: token, size: made.size, scale: made.scale) }
            } catch {
                logger.notice("Computer Use preview: no stream for window \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                guard let self else { return }
                queue.async { self.streamFailed(id, token: token) }
            }
        }
    }

    /// The stream of `window` at `longSide` with this session as its output (not started).
    private func makeStream(for window: SCWindow, longSide: Int) throws -> (stream: SCStream, size: (width: Int, height: Int), scale: Double) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let size = Self.evenSize(width: window.frame.width * scale, height: window.frame.height * scale, longSide: longSide)
        let stream = SCStream(filter: filter, configuration: Self.configuration(size), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        return (stream, size, scale)
    }

    /// The even pixel size H.264 wants, at most `longSide` on its long side.
    private static func evenSize(width: Double, height: Double, longSide: Int) -> (width: Int, height: Int) {
        let fitted = ComputerUsePreview.fitted(width: width, height: height, longSide: longSide)
        return (max(2, fitted.width & ~1), max(2, fitted.height & ~1))
    }

    private static func configuration(_ size: (width: Int, height: Int)) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.preservesAspectRatio = true
        return configuration
    }

    private func streamStarted(_ stream: SCStream, id: UInt32, token: Int, size: (width: Int, height: Int), scale: Double) {
        if token == startToken { starting = false }
        guard !ended, window == id, token == startToken else {
            // task-owner: stops a stream that started after its session moved on.
            Task.detached { try? await stream.stopCapture() }
            return
        }
        guard let encoder = Self.makeEncoder(width: size.width, height: size.height) else {
            // No encoder (no hardware session): stop the capture and send stills instead, for good.
            logger.notice("Computer Use preview: no encoder for \(size.width, privacy: .public)x\(size.height, privacy: .public); stills instead")
            encoderUnavailable = true
            // task-owner: stops the capture that has no encoder; nothing waits for it.
            Task.detached { try? await stream.stopCapture() }
            return sendStill()
        }
        self.stream = stream
        self.size = size
        self.encoder = encoder
        pointScale = scale
        startFailures = 0
        nextStartAt = nil
        keyframes.required = true
        send(state: "streaming", extra: ["width": size.width, "height": size.height, "window": streamGeneration(id)])
    }

    /// The generation `streaming` names for window `id`: the same while the session streams one
    /// window (a resize keeps it), a new one for another window.
    private func streamGeneration(_ id: UInt32) -> Int {
        if generationWindow != id {
            generationWindow = id
            generation += 1
        }
        return generation
    }

    /// A start failed (the window is not in ScreenCaptureKit's list yet, or the capture refused):
    /// stills stand in, and the stream is tried again after 2 s, doubling up to 30 s.
    private func streamFailed(_ id: UInt32, token: Int) {
        if token == startToken { starting = false }
        guard !ended, window == id, token == startToken else { return }
        noteStreamFailure()
        sendStill()
    }

    /// One more failure of this window's stream: the next start waits 2 s, doubling up to 30 s.
    private func noteStreamFailure() {
        startFailures += 1
        let wait = min(timing.retryBase * pow(2, Double(startFailures - 1)), timing.retryMax)
        nextStartAt = Date().addingTimeInterval(wait)
    }

    private func retryStreamIfDue() {
        guard let id = window, !starting, !encoderUnavailable, let next = nextStartAt, Date() >= next else { return }
        startStream(id)
    }

    /// Stops the capture and the encoder, keeping the window.
    private func tearDownStream() {
        if let stream {
            // task-owner: ends the capture; nothing waits for it.
            Task.detached { try? await stream.stopCapture() }
        }
        stream = nil
        if let encoder {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        reconfiguring = false
    }

    private func stopStream() {
        tearDownStream()
        window = nil
        starting = false
        startToken += 1
    }

    // MARK: Size (queue)

    /// The app asked for another long side (`L`): the stream and the stills follow it.
    private func setLongSide(_ side: Int) {
        guard side != longSide else { return }
        longSide = side
        stillAt = nil
        followWindowSize()
    }

    /// The window's pixel size at ``longSide`` changed by more than ``resizeThreshold`` (it was
    /// resized, or the app asked for another size): the stream takes the new size and a new encoder,
    /// whose first frame is a keyframe with its parameter sets, so the aspect follows the window.
    private func followWindowSize() {
        guard let stream, let id = window, !reconfiguring, let bounds = capture.bounds(id) else { return }
        let target = Self.evenSize(width: bounds.width * pointScale, height: bounds.height * pointScale, longSide: longSide)
        let changed = abs(Double(target.width - size.width)) > Double(size.width) * Self.resizeThreshold
            || abs(Double(target.height - size.height)) > Double(size.height) * Self.resizeThreshold
        guard changed else { return }
        reconfiguring = true
        let configuration = Self.configuration(target)
        // task-owner: one configuration change of this session's stream; it reports back on `queue`.
        Task.detached { [weak self] in
            let applied = (try? await stream.updateConfiguration(configuration)) != nil
            self?.queue.async { self?.resized(stream, to: target, applied: applied) }
        }
    }

    private func resized(_ stream: SCStream, to target: (width: Int, height: Int), applied: Bool) {
        guard stream === self.stream, !ended else { return }
        reconfiguring = false
        guard applied else { return }
        guard let encoder = Self.makeEncoder(width: target.width, height: target.height) else {
            logger.notice("Computer Use preview: no encoder after a resize; stills instead")
            encoderUnavailable = true
            tearDownStream()
            return sendStill()
        }
        if let old = self.encoder {
            VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(old)
        }
        self.encoder = encoder
        size = target
        keyframes.required = true
        send(state: "streaming", extra: ["width": target.width, "height": target.height, "window": generation])
    }

    // MARK: Stills (queue)

    /// One JPEG of the window, at most twice a second and one at a time: the fallback when no
    /// stream runs. Only the window the last look passed through the gate (``window``), never one
    /// looked up here. The capture runs in its own task, never on `writes`, so a slow
    /// ScreenCaptureKit holds neither the channel's writes nor its close; its result is sent only
    /// if it still may be when it comes.
    private func sendStill() {
        guard let id = window, stream == nil, !stillInFlight, !ended else { return }
        let now = Date()
        if let stillAt, now.timeIntervalSince(stillAt) < timing.still { return }
        stillAt = now
        stillInFlight = true
        let side = longSide, capture = capture, isEnded = isEnded
        // task-owner: the session's one still in flight (stillInFlight); its result comes back on `queue`.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<(jpeg: Data, width: Int, height: Int), ComputerUsePreview.Refusal>?
                = isEnded.withLock({ $0 }) ? nil : await capture.still(id, side)
            guard let self else { return }
            queue.async {
                // A deny-list edit, another window or a stream since the capture began: not sent.
                guard case .success(let frame)? = result, self.stillMaySend(window: id) else {
                    self.stillInFlight = false
                    return
                }
                self.send(state: "still", extra: [:])
                self.write(PreviewStreamWire.message(PreviewStreamWire.still, frame.jpeg))
                // The next still waits until this one is written: a slow app never queues stills.
                self.writes.async { [weak self] in self?.queue.async { self?.stillInFlight = false } }
            }
        }
    }

    /// Whether a still of window `id`, captured a moment ago, may go to the app now (queue).
    private func stillMaySend(window id: UInt32) -> Bool {
        guard !ended, stream == nil, window == id, let owner, let app = owner.id, !app.isEmpty else { return false }
        return !blocked(app, owner.name ?? app)
    }

    // MARK: Frames (queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, stream === self.stream, !ended, let encoder, let pixels = sampleBuffer.imageBuffer,
              Self.isComplete(sampleBuffer) else { return }
        // A frame of the size before a resize: its encoder is gone.
        guard CVPixelBufferGetWidth(pixels) == size.width, CVPixelBufferGetHeight(pixels) == size.height else { return }
        // A deny-list edit applies to the very next frame: the app is asked each time.
        if let owner, let id = owner.id, blocked(id, owner.name ?? id) {
            stopStream()
            send(state: PreviewStreamStep.state(for: .blocked))
            return
        }
        let time = sampleBuffer.presentationTimeStamp
        // The app fell behind and frames were dropped: a keyframe it can decode alone, at most one
        // per 300 ms however often it is asked.
        if backlog.withLock({ $0.takeKeyframeRequest() }) { keyframes.asked = true }
        let properties: CFDictionary? = keyframes.force(now: Date()) ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.encoded(sample)
        }
    }

    /// The capture stopped on its own (the window went off screen, or ScreenCaptureKit failed): the
    /// window stays, stills stand in, and the stream is tried again with the same backoff as a
    /// failed start (2 s, doubling up to 30 s), never at once on every look.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async {
            guard stream === self.stream, !self.ended else { return }
            logger.notice("Computer Use preview: the stream stopped: \(String(describing: error), privacy: .public)")
            self.tearDownStream()
            self.noteStreamFailure()
            self.send(state: "paused")
            self.sendStill()
        }
    }

    /// One encoded frame (VideoToolbox's thread): its parameter sets when they changed, then the frame.
    private func encoded(_ sample: CMSampleBuffer) {
        guard let data = Self.bytes(of: sample) else { return }
        let keyframe = Self.isKeyframe(sample)
        let micros = UInt64(max(0, sample.presentationTimeStamp.seconds) * 1_000_000)
        var out = Data()
        if keyframe, let format = sample.formatDescription, let sets = Self.parameterSets(format) {
            out.append(PreviewStreamWire.parameterSets(sps: sets.sps, pps: sets.pps))
        }
        out.append(PreviewStreamWire.frame(keyframe: keyframe, microseconds: micros, avcc: data))
        // A slow reader: at most a few frames wait for the channel; past that, frames are dropped
        // until a keyframe (asked for at once), so the app never decodes a frame whose reference it lost.
        guard backlog.withLock({ $0.admit(keyframe: keyframe, limit: Self.maximumPendingFrames) }) else { return }
        writes.async { [weak self] in
            guard let self else { return }
            let written = channel.write(out)
            backlog.withLock { $0.pending -= 1 }
            if !written { end() }
        }
    }

    // MARK: VideoToolbox

    /// A hardware H.264 encoder tuned for low latency: no frame reordering, real time, a keyframe
    /// at least every two seconds (a late-joining decoder catches up quickly).
    static func makeEncoder(width: Int, height: Int) -> VTCompressionSession? {
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                                encoderSpecification: specification, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        let bitrate = max(500_000, width * height * 4)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_ExpectedFrameRate: framesPerSecond,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
        ]
        VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    /// A ScreenCaptureKit frame that carries a new picture (not an idle or blank one).
    static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }

    static func bytes(of sample: CMSampleBuffer) -> Data? {
        guard let block = sample.dataBuffer else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == noErr ? data : nil
    }

    static func parameterSets(_ format: CMFormatDescription) -> (sps: Data, pps: Data)? {
        func set(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                    nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = set(0), let pps = set(1) else { return nil }
        return (sps, pps)
    }
}
