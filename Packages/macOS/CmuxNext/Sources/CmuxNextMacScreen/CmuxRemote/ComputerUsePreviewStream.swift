// SPDX-License-Identifier: GPL-3.0-or-later
public import AVFoundation
import CoreMedia
import Darwin
public import Foundation
import os

private let previewLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use-preview")

/// One live preview stream from cmux Remote: the window an agent's Computer Use session works in,
/// as hardware H.264 video on cmux Remote's app socket (`computer-use-preview`; the wire is
/// cmux Remote's `PreviewStreamWire`). The video decodes into ``displayLayer`` on the GPU, always
/// the newest frame (each one is shown at once, none queued). Closing the stream stops cmux
/// Remote's capture, so nothing is captured while nobody watches.
public nonisolated final class ComputerUsePreviewStream: @unchecked Sendable { // crash-allow: the reader thread owns `format`; `socket` is set once before it starts
    /// What the stream says besides its frames.
    public enum Event: Sendable, Equatable {
        /// The worker's state: streaming (its picture size and app), a still stands in, the window
        /// is gone or private, or the stream paused.
        case status(ComputerUsePreviewStatus)
        /// A JPEG still (the fallback when no stream starts).
        case still(Data)
        /// The channel closed.
        case closed
    }

    /// The video, decoded on the GPU. Created on the main thread; frames reach it from the reader.
    public let displayLayer: AVSampleBufferDisplayLayer
    private let session: String
    private let longSide: Int
    private let onEvent: @MainActor @Sendable (Event) -> Void
    private let state = OSAllocatedUnfairLock(initialState: (socket: Int32(-1), closed: false))
    private var format: CMVideoFormatDescription?

    /// - Parameters:
    ///   - session: The agent session whose window to stream.
    ///   - longSide: The picture's longest side in pixels.
    ///   - onEvent: Statuses, stills and the close, on the main actor.
    @MainActor
    public init(session: String, longSide: Int, onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
        self.session = session
        self.longSide = longSide
        self.onEvent = onEvent
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
    }

    /// Opens the channel through `remote` and starts reading; an error closes the stream at once.
    @MainActor
    public func start(remote: CmuxRemoteService) {
        let session = session, longSide = longSide
        // task-owner: opens this stream's channel; the reader thread then owns it until `stop`.
        Task { [weak self] in
            do {
                let (socket, _, _) = try await remote.openChannel("computer-use-preview")
                let request = try JSONSerialization.data(withJSONObject: ["session": session, "long_side": longSide]) + Data([0x0A])
                guard let self, RemoteSocket.writeAll(socket, request) else {
                    close(socket)
                    return
                }
                let keep = self.state.withLock { state -> Bool in
                    guard !state.closed else { return false }
                    state.socket = socket
                    return true
                }
                guard keep else {
                    close(socket)
                    return
                }
                let reader = Thread { [weak self] in self?.read(socket) }
                reader.name = "cmux-cu-preview-read"
                reader.qualityOfService = .userInteractive
                reader.start()
            } catch {
                previewLogger.notice("Computer Use preview: no channel: \(String(describing: error), privacy: .public)")
                self?.deliver(.closed)
            }
        }
    }

    /// Stops the stream: the channel closes, and cmux Remote stops capturing.
    public func stop() {
        let socket = state.withLock { state -> Int32 in
            state.closed = true
            let socket = state.socket
            state.socket = -1
            return socket
        }
        if socket >= 0 {
            shutdown(socket, SHUT_RDWR)
            close(socket)
        }
    }

    deinit { stop() }

    // MARK: Reading (the reader thread)

    /// Reads the channel until it closes (internal: tests feed it a socket pair).
    func read(_ socket: Int32) {
        var header = [UInt8](repeating: 0, count: 5)
        while readExactly(socket, &header, count: 5) {
            let length = Int(UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4]))
            guard length <= ComputerUsePreviewWire.maximumPayload else { break }
            var payload = [UInt8](repeating: 0, count: length)
            guard length == 0 || readExactly(socket, &payload, count: length) else { break }
            handle(kind: header[0], Data(payload))
        }
        deliver(.closed)
    }

    private func readExactly(_ socket: Int32, _ buffer: inout [UInt8], count: Int) -> Bool {
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

    private func handle(kind: UInt8, _ payload: Data) {
        switch kind {
        case ComputerUsePreviewWire.status:
            guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                  let status = ComputerUsePreviewStatus(object) else { return }
            if status.state == .blocked { displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
            deliver(.status(status))
        case ComputerUsePreviewWire.parameterSets:
            guard let sets = ComputerUsePreviewWire.parameterSets(payload) else { return }
            format = Self.format(sps: sets.sps, pps: sets.pps)
        case ComputerUsePreviewWire.frame:
            guard let format, let frame = ComputerUsePreviewWire.frame(payload),
                  let sample = Self.sample(frame.avcc, format: format, microseconds: frame.microseconds) else { return }
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        case ComputerUsePreviewWire.still:
            deliver(.still(payload))
        default:
            return
        }
    }

    /// Events reach the main actor in the order the channel sent them (a still after its status).
    private func deliver(_ event: Event) {
        let onEvent = onEvent
        DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(event) } } // main-proof: DispatchQueue.main runs on the main thread
    }

    // MARK: CoreMedia

    static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
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
    static func sample(_ avcc: Data, format: CMVideoFormatDescription, microseconds: UInt64) -> CMSampleBuffer? {
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

/// What the worker says of a stream (`S` messages).
public nonisolated struct ComputerUsePreviewStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        /// Live video.
        case streaming
        /// No stream started: stills stand in.
        case still
        /// The session has no window now (it closed, or the agent has not used one yet).
        case noWindow = "no_window"
        /// The window's app is kept private: no picture at all.
        case blocked
        /// The stream stopped (the window moved off screen, or capture failed).
        case paused
    }

    public var state: State
    public var width: Int?
    public var height: Int?
    public var appName: String?

    public init(state: State, width: Int? = nil, height: Int? = nil, appName: String? = nil) {
        self.state = state
        self.width = width
        self.height = height
        self.appName = appName
    }

    /// The status of an `S` message; nil for a state this build does not know (a newer worker's).
    public init?(_ object: [String: Any]) {
        guard let raw = object["state"] as? String, let state = State(rawValue: raw) else { return nil }
        let app = (object["app"] as? [String: Any])?["name"] as? String
        self.init(state: state, width: (object["width"] as? NSNumber)?.intValue, height: (object["height"] as? NSNumber)?.intValue,
                  appName: app?.isEmpty == false ? app : nil)
    }
}

/// The preview channel's messages as the app reads them (cmux Remote's `PreviewStreamWire`): a kind
/// byte, a big-endian UInt32 length, the payload. An unknown kind is skipped.
public nonisolated struct ComputerUsePreviewWire: Sendable {
    public static let status: UInt8 = 0x53
    public static let parameterSets: UInt8 = 0x50
    public static let frame: UInt8 = 0x46
    public static let still: UInt8 = 0x4A
    public static let maximumPayload = 8 * 1024 * 1024

    public init() {}

    /// The SPS and PPS of a `P` payload.
    public static func parameterSets(_ payload: Data) -> (sps: Data, pps: Data)? {
        let bytes = [UInt8](payload)
        var offset = 0
        func next() -> Data? {
            guard offset + 2 <= bytes.count else { return nil }
            let length = Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
            offset += 2
            guard length > 0, offset + length <= bytes.count else { return nil }
            defer { offset += length }
            return Data(bytes[offset..<offset + length])
        }
        guard let sps = next(), let pps = next() else { return nil }
        return (sps, pps)
    }

    /// The keyframe flag, time and access unit of an `F` payload.
    public static func frame(_ payload: Data) -> (keyframe: Bool, microseconds: UInt64, avcc: Data)? {
        let bytes = [UInt8](payload)
        guard bytes.count > 9 else { return nil }
        var micros: UInt64 = 0
        for byte in bytes[1..<9] { micros = micros << 8 | UInt64(byte) }
        return (bytes[0] & 1 == 1, micros, Data(bytes[9...]))
    }
}
