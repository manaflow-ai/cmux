// SPDX-License-Identifier: GPL-3.0-or-later
public import AVFoundation
import CoreMedia
public import CoreGraphics
import Darwin
public import Foundation
import ImageIO
import CmuxNextCompat
import CmuxNextWakeups
import os

private let previewLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use-preview")

/// One live preview stream from cmux Remote: the window an agent's Computer Use session works in,
/// as hardware H.264 video on cmux Remote's app socket (`computer-use-preview`; the wire is
/// cmux Remote's `PreviewStreamWire`). A reader thread parses the channel and builds each frame's
/// sample; the main queue only enqueues it, in order, into ``displayLayer``, which decodes on the
/// GPU and shows it at once (the newest frame, none queued). Closing the stream stops cmux Remote's
/// capture, so nothing is captured while nobody watches.
@MainActor
public final class ComputerUsePreviewStream {
    /// What the stream says besides its frames (on the main actor).
    public enum Event: Equatable {
        /// The worker's state: streaming (its picture size and app), a still stands in, the window
        /// is gone or private, or the stream paused.
        case status(ComputerUsePreviewStatus)
        /// The first video frame since the stream (re)started is in the layer: there is a picture.
        case pictured
        /// cmux Remote shows another window now (a `streaming` or `still` status names another
        /// window generation): every picture of the old one is gone, the stream's layer is cleared,
        /// and nothing shows until the new window's first frame or still.
        case windowChanged
        /// A still (the fallback when no stream runs), decoded off the main thread.
        case still(CGImage)
        /// The channel closed.
        case closed
    }

    /// What the reader hands the main queue: a status, word that a decoded still waits in
    /// ``stills``, the close, or a frame ready to enqueue.
    enum Output: Sendable {
        case status(ComputerUsePreviewStatus)
        /// Still number `sequence` waits in ``stills``; the main queue takes it only if it is still
        /// the newest (a newer one, or a `blocked` that emptied the slot, makes this word stale).
        case stillReady(sequence: UInt64)
        case closed
        case sample(CMSampleBuffer)
    }

    /// The video, decoded on the GPU.
    public let displayLayer: AVSampleBufferDisplayLayer
    private let session: String
    private let onEvent: @MainActor (Event) -> Void
    /// The picture's long side asked for now (the request, then `L` lines).
    private let side: OSAllocatedUnfairLock<Int>
    /// Every line the app writes on the channel goes through this queue, in order, off the main thread.
    private let control = DispatchQueue(label: "cmux-cu-preview-control", qos: .userInitiated)
    /// The channel's socket (the reader thread closes it when it ends) and whether ``stop()`` ran.
    private let state = OSAllocatedUnfairLock(initialState: (socket: Int32(-1), closed: false))
    /// Frames handed to the main queue and not enqueued yet (the reader drops frames past
    /// ``maximumPendingSamples`` until a keyframe).
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    /// Stills are shown only after a `streaming` or `still` status: never after `blocked` until the
    /// worker says the window may show again.
    private var acceptsStills = false
    /// Frames are shown only after a `streaming` status, and not after any other status until the
    /// next `streaming` (defence in depth: cmux Remote stops a blocked stream itself).
    private var acceptsFrames = false
    /// Frames enqueued into the layer so far (tests).
    private(set) var framesShown = 0
    /// A frame is in the layer since the last (re)start, `blocked`, close or window change.
    private var hasPicture = false
    /// The window generation the last `streaming` or `still` status named: the window whose picture
    /// (a frame or a still) may be up. Another one clears it.
    private var pictureWindow: Int?
    /// The latest decoded still waiting for the main queue (the reader replaces an older one).
    let stills = ComputerUsePreviewStillSlot()

    /// The most frames waiting for the main queue; past it the reader drops frames until a keyframe.
    nonisolated static let maximumPendingSamples = 3

    /// - Parameters:
    ///   - session: The agent session whose window to stream.
    ///   - longSide: The picture's longest side in pixels.
    ///   - onEvent: Statuses, stills and the close, in the order the channel sent them; none after ``stop()``.
    public init(session: String, longSide: Int, onEvent: @escaping @MainActor (Event) -> Void) {
        self.session = session
        side = OSAllocatedUnfairLock(initialState: longSide)
        self.onEvent = onEvent
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
    }

    /// Opens the channel through `remote`, sends the request (on the control queue) and starts the
    /// reader thread, which reads until the channel closes; an error closes the stream at once.
    public func start(remote: CmuxRemoteService) {
        let session = session, state = state, side = side, control = control
        // task-owner: opens this stream's channel; the reader thread then owns it until it ends.
        Task { [weak self] in
            do {
                let (socket, _, _) = try await remote.openChannel("computer-use-preview")
                let keep = state.withLock { state -> Bool in
                    guard !state.closed else { return false }
                    state.socket = socket
                    return true
                }
                guard keep, let self else {
                    close(socket)
                    return
                }
                // The request line goes first: queued in this main-actor turn, before any `L` a later
                // turn queues, on the one queue every app line is written from.
                control.async {
                    let line = try? JSONSerialization.data(withJSONObject: ["session": session, "long_side": side.withLock { $0 }])
                    if let line { _ = RemoteSocket.writeAll(socket, line + Data([0x0A])) }
                }
                let deliver = self.deliverer(), pending = self.pending, ask = self.askKeyframe, stills = self.stills
                let reader = Thread {
                    Self.read(socket, backlog: { pending.withLock { $0 } }, askKeyframe: ask, stills: stills, deliver)
                    // Only this thread closes the socket, after its last read and after the control
                    // queue's writes (none starts once the socket is cleared): `stop` only shuts it
                    // down, so the descriptor number is never reused under a read or write in flight.
                    state.withLock { $0.socket = -1 }
                    control.blockingSync {}
                    close(socket)
                }
                reader.name = "cmux-cu-preview-read"
                reader.qualityOfService = .userInteractive
                reader.start()
            } catch {
                previewLogger.notice("Computer Use preview: no channel: \(String(describing: error), privacy: .public)")
                self?.receive(.closed)
            }
        }
    }

    /// Asks cmux Remote for another picture size (`L <side>`): the expanded view's, or the card's at
    /// its new size. The stream keeps running; its next frames come at the new size.
    public func request(longSide: Int) {
        let changed = side.withLock { side -> Bool in
            guard side != longSide else { return false }
            side = longSide
            return true
        }
        if changed { send(Data("L \(longSide)\n".utf8)) }
    }

    /// The `K` line for the reader thread, once each time it starts dropping (cmux Remote forces
    /// at most one keyframe per 300 ms however often it is asked).
    private var askKeyframe: @Sendable () -> Void {
        let control = control, state = state
        return { Self.write(PreviewChannelLine.keyframeRequest, on: control, state: state) }
    }

    /// Writes one app line on the control queue, to the channel's socket while it is open.
    private func send(_ line: Data) { Self.write(line, on: control, state: state) }

    private nonisolated static func write(_ line: Data, on control: DispatchQueue,
                                          state: OSAllocatedUnfairLock<(socket: Int32, closed: Bool)>) {
        control.async {
            let socket = state.withLock { $0.closed ? -1 : $0.socket }
            if socket >= 0 { _ = RemoteSocket.writeAll(socket, line) }
        }
    }

    /// Stops the stream: the channel shuts down (the reader then ends and closes it), cmux Remote
    /// stops capturing, and no event or frame is delivered after this.
    public nonisolated func stop() {
        state.withLock { state in
            state.closed = true
            if state.socket >= 0 { shutdown(state.socket, SHUT_RDWR) }
        }
    }

    nonisolated deinit { stop() }

    /// The reader's outputs onto the main queue, in order, for this stream while it lives.
    func deliverer() -> @Sendable (Output) -> Void {
        let pending = pending
        return { [weak self] output in
            if case .sample = output { pending.withLock { $0 += 1 } }
            MainDelivery().later { // the main queue keeps their order
                if case .sample = output { pending.withLock { $0 -= 1 } }
                self?.receive(output)
            }
        }
    }

    /// One output on the main actor: a frame goes to the layer (a failed renderer is flushed first),
    /// a private window takes the picture off at once and stills stop until it may show again, every
    /// event goes on. Nothing after ``stop()``.
    func receive(_ output: Output) {
        guard !state.withLock({ $0.closed }) else { return }
        let renderer = displayLayer.sampleBufferRenderer
        switch output {
        case .sample(let sample):
            guard acceptsFrames else { return }
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
            framesShown += 1
            if !hasPicture {
                hasPicture = true
                onEvent(.pictured)
            }
        case .status(let status):
            acceptsFrames = status.state == .streaming
            // Another window is the session's now: no picture of the old one stays, not its last
            // frame, nor the still on screen (the presenter clears it on `windowChanged`); the reader
            // already emptied the still slot in wire order. The old window's privacy is no longer checked.
            if Self.changesWindow(&pictureWindow, status) {
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
                hasPicture = false
                onEvent(.windowChanged)
            }
            switch status.state {
            case .blocked:
                // The reader emptied the still slot when it read this status.
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
                acceptsStills = false
                hasPicture = false
            case .streaming, .still:
                acceptsStills = true
            case .noWindow:
                // The session's window is gone (closed, or it no longer has one): its last picture
                // goes, as on a window change, and nothing shows until a window's first picture.
                // The reader emptied the still slot when it read this status.
                renderer.flush(removingDisplayedImage: true, completionHandler: nil)
                hasPicture = false
                pictureWindow = nil
            case .paused:
                break
            }
            onEvent(.status(status))
        case .stillReady(let sequence):
            // The newest still only, and only the one this word is about; none while the window may not show.
            guard let image = stills.take(sequence: sequence), acceptsStills else { return }
            onEvent(.still(image))
        case .closed:
            // The channel ended: its last picture does not linger while a new one opens.
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            acceptsFrames = false
            acceptsStills = false
            hasPicture = false
            stills.clear()
            onEvent(.closed)
        }
    }

    /// Whether `status` names another window than `shown` (the generation whose picture may be up),
    /// updating it: any status naming a window counts, and a `streaming` or `still` status naming
    /// none (an older cmux Remote) counts as a change once a window was named, to fail safe.
    nonisolated static func changesWindow(_ shown: inout Int?, _ status: ComputerUsePreviewStatus) -> Bool {
        if let window = status.window {
            defer { shown = window }
            return shown.map { $0 != window } ?? false
        }
        guard status.state == .streaming || status.state == .still, shown != nil else { return false }
        shown = nil
        return true
    }

    // MARK: Reading (the reader thread)

    /// Reads the channel until it closes, then says so: statuses and stills as events, parameter
    /// sets into the format, frames into ready samples. An unknown kind or state is skipped; a
    /// payload past the wire's limit ends the stream. While `backlog` (frames not yet enqueued) is
    /// at ``maximumPendingSamples`` the reader drops frames, and then every frame until a keyframe,
    /// so the decoder never gets a frame whose reference it lost.
    /// `askKeyframe` runs once each time the reader starts dropping: it asks cmux Remote for a
    /// keyframe, so the picture resumes at once instead of at the next scheduled one.
    /// A still is decoded here, off the main thread, into `stills`, which keeps only the newest:
    /// the main queue hears of it once however many come before it takes it.
    nonisolated static func read(_ socket: Int32, backlog: () -> Int = { 0 }, askKeyframe: () -> Void = {},
                                 stills: ComputerUsePreviewStillSlot = ComputerUsePreviewStillSlot(),
                                 _ deliver: @Sendable (Output) -> Void) {
        var header = [UInt8](repeating: 0, count: 5)
        var format: CMVideoFormatDescription?
        var skipping = false
        var window: Int?
        while readExactly(socket, &header, count: 5) {
            let length = Int(UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4]))
            guard length <= ComputerUsePreviewWire.maximumPayload else { break }
            var payload = [UInt8](repeating: 0, count: length)
            guard length == 0 || readExactly(socket, &payload, count: length) else { break }
            let data = Data(payload)
            switch header[0] {
            case ComputerUsePreviewWire.status:
                if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let status = ComputerUsePreviewStatus(object) {
                    // In wire order: a still read before `blocked` or another window is never shown,
                    // and one read after it (the new window's first) is never dropped.
                    let changed = Self.changesWindow(&window, status)
                    if status.state == .blocked || status.state == .noWindow || changed { stills.clear() }
                    if status.state == .noWindow { window = nil }
                    deliver(.status(status))
                }
            case ComputerUsePreviewWire.parameterSets:
                if let sets = ComputerUsePreviewWire.parameterSets(data) { format = Self.format(sps: sets.sps, pps: sets.pps) }
            case ComputerUsePreviewWire.frame:
                guard let format, let frame = ComputerUsePreviewWire.frame(data) else { break }
                if frame.keyframe { skipping = false }
                if !skipping, backlog() >= maximumPendingSamples {
                    skipping = true
                    askKeyframe()
                }
                if !skipping, let sample = Self.sample(frame.avcc, format: format, microseconds: frame.microseconds) {
                    deliver(.sample(sample))
                }
            case ComputerUsePreviewWire.still:
                if let sequence = stills.put(jpeg: data) { deliver(.stillReady(sequence: sequence)) }
            default:
                break
            }
        }
        deliver(.closed)
    }

    private nonisolated static func readExactly(_ socket: Int32, _ buffer: inout [UInt8], count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress.map { $0 + offset }, count - offset) }
            if got > 0 {
                offset += got
            } else if got < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    // MARK: CoreMedia

    nonisolated static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes -> OSStatus in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        return status == noErr ? description : nil
    }

    /// One access unit as a sample shown as soon as it decodes (the newest frame, never a queue).
    nonisolated static func sample(_ avcc: Data, format: CMVideoFormatDescription, microseconds: UInt64) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(microseconds), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
