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

/// One app connection: streams the window `request.session` works in, re-checking the window and
/// its app's privacy every half second and its app's privacy on each frame, until the app closes it.
final class PreviewStreamSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable { // crash-allow: mutable state lives on `queue` only
    /// How often the session's window and its owner are looked at again.
    static let lookInterval: DispatchTimeInterval = .milliseconds(500)
    /// The stream's highest frame rate.
    static let framesPerSecond: Int32 = 30
    /// The most encoded frames waiting for the channel; past it frames are dropped until a keyframe.
    static let maximumPendingFrames = 3

    private let channel: LineChannel
    private let request: PreviewStreamWire.Request
    private let windowOf: @Sendable (String) -> ComputerUsePreview.SessionWindow?
    private let blocked: @Sendable (String, String) -> Bool
    private let queue = DispatchQueue(label: "remote-cu-preview.session")
    private let writes = DispatchQueue(label: "remote-cu-preview.write")
    private let closed = DispatchSemaphore(value: 0)
    /// Frames handed to `writes` and not yet written, and whether frames are being dropped until the
    /// next keyframe (the app is reading slower than the stream). VideoToolbox's thread and `writes`.
    private let backlog = OSAllocatedUnfairLock(initialState: PreviewFrameBacklog())

    // `queue` only.
    private var window: UInt32?
    private var owner: ComputerUseActivity.App?
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var size = (width: 0, height: 0)
    private var forceKeyframe = true
    private var lastState = ""
    private var ended = false
    private var timer: (any DispatchSourceTimer)?
    private var stillAt: Date?

    init(channel: LineChannel, request: PreviewStreamWire.Request,
         windowOf: @escaping @Sendable (String) -> ComputerUsePreview.SessionWindow?,
         blocked: @escaping @Sendable (String, String) -> Bool) {
        self.channel = channel
        self.request = request
        self.windowOf = windowOf
        self.blocked = blocked
    }

    /// Streams until the app closes the channel (this connection's own thread waits).
    func run() {
        queue.async { self.look() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.lookInterval, repeating: Self.lookInterval)
        timer.setEventHandler { [weak self] in self?.look() }
        queue.sync { self.timer = timer }
        timer.resume()
        // The app sends nothing more: a read ends when it closes the channel.
        let reader = Thread { [weak self] in
            while self?.channel.readLine() != nil {}
            self?.end()
        }
        reader.name = "remote-cu-preview-read"
        reader.start()
        closed.wait()
    }

    private func end() {
        queue.async {
            guard !self.ended else { return }
            self.ended = true
            self.timer?.cancel()
            self.stopStream()
            self.channel.close()
            self.closed.signal()
        }
    }

    // MARK: Looking at the window (queue)

    private func look() {
        guard !ended else { return }
        let place = windowOf(request.session)
        let owner = place.flatMap { ComputerUseActivityReporter.owner(ofWindow: $0.window) }
        let gate = ComputerUsePreview.gate(window: place, owner: owner, blocked: blocked)
        if case .success = gate { self.owner = owner }
        switch PreviewStreamStep.next(streaming: window, gate: gate) {
        case .keep:
            if stream == nil { sendStill() } // the stream never started: a still now and then
        case .start(let id), .restart(let id):
            stopStream()
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
        forceKeyframe = true
        // task-owner: one stream start for this session; it reports back on `queue`.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let content: SCShareableContent
                if let cached = ScreenCapture.reusableContent(holding: id) {
                    content = cached
                } else {
                    content = try await ScreenCapture.freshContent()
                }
                guard let scWindow = content.windows.first(where: { $0.windowID == id }) else { throw ScreenCapture.Failure.noWindow(id) }
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let scale = Double(filter.pointPixelScale)
                let fitted = ComputerUsePreview.fitted(width: scWindow.frame.width * scale, height: scWindow.frame.height * scale,
                                                       longSide: request.longSide)
                // H.264 wants even sizes.
                let size = (width: max(2, fitted.width & ~1), height: max(2, fitted.height & ~1))
                let configuration = SCStreamConfiguration()
                configuration.width = size.width
                configuration.height = size.height
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
                configuration.queueDepth = 3
                configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.preservesAspectRatio = true
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                queue.async { self.streamStarted(stream, id: id, size: size) }
            } catch {
                logger.notice("Computer Use preview: no stream for window \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                queue.async { self.streamFailed(id) }
            }
        }
    }

    private func streamStarted(_ stream: SCStream, id: UInt32, size: (width: Int, height: Int)) {
        guard !ended, window == id else {
            // task-owner: stops a stream that started after its session moved on.
            Task.detached { try? await stream.stopCapture() }
            return
        }
        self.stream = stream
        self.size = size
        encoder = Self.makeEncoder(width: size.width, height: size.height)
        send(state: "streaming", extra: ["width": size.width, "height": size.height])
    }

    private func streamFailed(_ id: UInt32) {
        guard !ended, window == id else { return }
        sendStill()
    }

    private func stopStream() {
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
        window = nil
    }

    /// One JPEG of the window, at most twice a second: the fallback when no stream runs. Only the
    /// window the last look passed through the gate (``window``), never one looked up here.
    private func sendStill() {
        guard let id = window, stream == nil else { return }
        let now = Date()
        if let stillAt, now.timeIntervalSince(stillAt) < 0.5 { return }
        stillAt = now
        // The still waits on ScreenCaptureKit (bounded): off this queue.
        let side = request.longSide
        writes.async { [weak self] in
            guard let self, case .success(let frame) = ComputerUsePreview.capture(window: id, longSide: side) else { return }
            queue.async {
                // The capture took a while: send it only if this is still the window to show, no stream
                // replaced it, and its app is still allowed now (a deny-list edit during the capture
                // already sent `blocked`; a stale still must not follow it).
                guard self.stillMaySend(window: id) else { return }
                self.send(state: "still", extra: [:])
                self.write(PreviewStreamWire.message(PreviewStreamWire.still, frame.jpeg))
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
        // A deny-list edit applies to the very next frame: the app is asked each time.
        if let owner, let id = owner.id, blocked(id, owner.name ?? id) {
            stopStream()
            send(state: PreviewStreamStep.state(for: .blocked))
            return
        }
        let time = sampleBuffer.presentationTimeStamp
        // The app fell behind and frames were dropped: the next frame is a keyframe it can decode alone.
        if backlog.withLock({ $0.takeKeyframeRequest() }) { forceKeyframe = true }
        let properties: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.encoded(sample)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        queue.async {
            guard stream === self.stream else { return }
            self.stream = nil
            self.window = nil
            self.send(state: "paused")
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
