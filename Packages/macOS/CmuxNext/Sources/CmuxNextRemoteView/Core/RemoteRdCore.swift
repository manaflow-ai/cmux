import CCmuxRdFFI
public import Foundation

/// The viewer side of one `cmux.rd/1` display stream, implemented by the
/// shared Rust core (crate cmux-rd-ffi, the same reassembly, FEC and feedback
/// code the host's bench viewer uses). Received bytes go in; complete access
/// units, transport messages and feedback datagrams come out.
///
/// No I/O, threads or timers inside: the owner calls `tick` and `feedback`
/// at `nextDeadlineMicros` (one timer, no polling). Not thread-safe: one
/// actor owns an instance, so the type is not `Sendable`. Times are the
/// owner's monotonic clock in microseconds.
public nonisolated final class RemoteRdCore {
    /// How the session's datagrams travel.
    public enum Carrier: Sendable, Hashable {
        /// Overlay datagrams: push one datagram per call.
        case datagram
        /// One reliable byte stream: push bytes in any chunks.
        case stream

        var raw: UInt32 {
            switch self {
            case .datagram: UInt32(CMUX_RD_CARRIER_DATAGRAM)
            case .stream: UInt32(CMUX_RD_CARRIER_STREAM)
            }
        }
    }

    /// The carrier this receiver was created for.
    public let carrier: Carrier
    private let handle: OpaquePointer

    /// `deadlineMicros`: how long a frame may wait for missing shards.
    /// `nackAfterMicros`: how long a frame waits before its gaps are NACKed.
    /// Nil only when the core cannot allocate a receiver.
    public init?(carrier: Carrier, deadlineMicros: UInt64 = 200_000, nackAfterMicros: UInt64 = 5_000) {
        guard let handle = cmux_rd_receiver_new(carrier.raw, deadlineMicros, nackAfterMicros) else { return nil }
        self.carrier = carrier
        self.handle = handle
    }

    deinit {
        cmux_rd_receiver_free(handle)
    }

    /// The C ABI version the linked library implements.
    public static var abiVersion: UInt32 { cmux_rd_ffi_abi_version() }

    /// Adds one received datagram (datagram carrier). Returns the frames ready.
    @discardableResult
    public func push(datagram: Data, nowMicros: UInt64) throws(RemoteRdCoreError) -> Int {
        let code = datagram.withUnsafeBytes { raw in
            cmux_rd_receiver_push_datagram(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, nowMicros)
        }
        return try RemoteRdCoreError.check(code)
    }

    /// Adds received stream bytes (stream carrier). Returns the frames ready.
    @discardableResult
    public func push(streamBytes: Data, nowMicros: UInt64) throws(RemoteRdCoreError) -> Int {
        let code = streamBytes.withUnsafeBytes { raw in
            cmux_rd_receiver_push_stream(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, nowMicros)
        }
        return try RemoteRdCoreError.check(code)
    }

    /// Drops frames past their deadline. Returns the frames ready.
    @discardableResult
    public func tick(nowMicros: UInt64) throws(RemoteRdCoreError) -> Int {
        try RemoteRdCoreError.check(cmux_rd_receiver_tick(handle, nowMicros))
    }

    /// The oldest complete access unit, or nil when none is ready.
    public func popAccessUnit(codec: RemoteVideoCodec) throws(RemoteRdCoreError) -> RemoteAccessUnit? {
        var frame = CmuxRdFrame()
        guard try RemoteRdCoreError.check(cmux_rd_receiver_pop_frame(handle, &frame)) == 1 else { return nil }
        return Self.unit(frame, codec: codec)
    }

    /// The oldest queued transport message, or nil when none is queued.
    public func popMessage() throws(RemoteRdCoreError) -> RemoteRdMessage? {
        var message = CmuxRdMessage()
        guard try RemoteRdCoreError.check(cmux_rd_receiver_pop_message(handle, &message)) == 1 else { return nil }
        return Self.message(message)
    }

    /// Records one decode time for the feedback's median.
    public func noteDecode(micros: UInt32) throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_receiver_note_decode(handle, micros))
    }

    /// Asks the host for a keyframe (after a decode error or a frame gap)
    /// in every feedback until one is released.
    public func requestKeyframe() throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_receiver_request_keyframe(handle))
    }

    /// Every feedback datagram due at `nowMicros`, framed for the carrier and
    /// ready to send in order (usually zero or one).
    public func feedback(nowMicros: UInt64) throws(RemoteRdCoreError) -> [Data] {
        var out: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        // Bounded: the core keeps at most eight messages' worth of arrivals.
        for _ in 0..<Self.maxFeedbackCalls {
            var length = 0
            let code = buffer.withUnsafeMutableBufferPointer { buf in
                cmux_rd_receiver_feedback(handle, nowMicros, buf.baseAddress, buf.count, &length)
            }
            if code < 0, RemoteRdCoreError(code: code) == .buffer {
                // Too small: the core keeps the datagram; grow and ask again.
                buffer = [UInt8](repeating: 0, count: length)
                continue
            }
            guard try RemoteRdCoreError.check(code) == 1 else { break }
            out.append(Data(buffer[0..<length]))
        }
        return out
    }

    private static let maxFeedbackCalls = 32

    /// When `tick` and `feedback` must run next, or nil when the receiver is
    /// unusable. A value at or before now means at once.
    public var nextDeadlineMicros: UInt64? {
        let value = cmux_rd_receiver_next_deadline_us(handle)
        return value == UInt64.max ? nil : value
    }

    /// The receiver's counters.
    public func stats() throws(RemoteRdCoreError) -> RemoteRdStats {
        var raw = CmuxRdStats()
        _ = try RemoteRdCoreError.check(cmux_rd_receiver_stats(handle, &raw))
        return RemoteRdStats(
            ackedFrame: raw.acked_frame,
            needRecovery: raw.need_recovery,
            framesReleased: raw.frames_released,
            framesLost: raw.frames_lost
        )
    }

    /// Frames `payload` for the stream carrier: a control message (JSON) when
    /// `control` is true, else one datagram.
    public static func streamFrame(_ payload: Data, control: Bool) throws(RemoteRdCoreError) -> Data {
        let kind = UInt32(control ? CMUX_RD_MESSAGE_CONTROL : CMUX_RD_MESSAGE_DATAGRAM)
        var out = [UInt8](repeating: 0, count: payload.count + 5)
        var length = 0
        let code = payload.withUnsafeBytes { raw in
            out.withUnsafeMutableBufferPointer { buf in
                cmux_rd_encode_stream_frame(
                    kind, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, buf.baseAddress, buf.count, &length
                )
            }
        }
        _ = try RemoteRdCoreError.check(code)
        return Data(out[0..<length])
    }

    /// A popped frame as an access unit (shared with `RemoteRdSession`).
    static func unit(_ frame: CmuxRdFrame, codec: RemoteVideoCodec) -> RemoteAccessUnit {
        RemoteAccessUnit(
            frame: frame.frame,
            flags: RemoteFrameFlags(rawValue: frame.flags),
            tCaptureMicros: frame.t_capture_us,
            data: copy(frame.data, frame.len),
            codec: codec
        )
    }

    /// A popped message (shared with `RemoteRdSession`).
    static func message(_ message: CmuxRdMessage) -> RemoteRdMessage {
        let bytes = copy(message.data, message.len)
        switch UInt32(message.kind) {
        case UInt32(CMUX_RD_MESSAGE_CONTROL): return .control(bytes)
        case UInt32(CMUX_RD_MESSAGE_BULK): return .bulk(bytes)
        default: return .datagram(bytes)
        }
    }

    private static func copy(_ pointer: UnsafePointer<UInt8>?, _ count: Int) -> Data {
        guard let pointer, count > 0 else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}
