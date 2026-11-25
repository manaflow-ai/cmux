import CCmuxRdFFI
public import Foundation

/// The viewer side of every display stream of one `cmux.rd/1` session (rd
/// change C6): the shared Rust core (cmux-rd-ffi `cmux_rd_session_*`) sends
/// each video or parity datagram to the reassembler of the stream its header
/// names, so a popup surface's frames (rb/1 `rb.surface.show {stream}`) never
/// mix with the page's. Stream 0 is open from the start; the owner opens
/// others before their datagrams arrive (a datagram of a stream that is not
/// open is skipped). Feedback and keyframe requests are per stream.
///
/// Like `RemoteRdCore`: no I/O, threads or timers; not thread-safe, one
/// actor owns an instance.
public nonisolated final class RemoteRdSession {
    public let carrier: RemoteRdCore.Carrier
    private let handle: OpaquePointer

    /// Nil only when the core cannot allocate a session.
    public init?(carrier: RemoteRdCore.Carrier, deadlineMicros: UInt64 = 200_000, nackAfterMicros: UInt64 = 5_000) {
        guard let handle = cmux_rd_session_new(carrier.raw, deadlineMicros, nackAfterMicros) else { return nil }
        self.carrier = carrier
        self.handle = handle
    }

    deinit {
        cmux_rd_session_free(handle)
    }

    /// Accepts datagrams of `stream` from now on (idempotent). Throws
    /// `.stream` past the core's stream limit.
    public func openStream(_ stream: UInt16) throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_session_open_stream(handle, stream))
    }

    /// Drops `stream` and its frames. Throws `.stream` when it is not open.
    public func closeStream(_ stream: UInt16) throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_session_close_stream(handle, stream))
    }

    /// Adds received stream bytes (stream carrier). Returns the frames ready.
    @discardableResult
    public func push(streamBytes: Data, nowMicros: UInt64) throws(RemoteRdCoreError) -> Int {
        let code = streamBytes.withUnsafeBytes { raw in
            cmux_rd_session_push_stream(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, nowMicros)
        }
        return try RemoteRdCoreError.check(code)
    }

    /// Adds one received datagram (datagram carrier). Returns the frames ready.
    @discardableResult
    public func push(datagram: Data, nowMicros: UInt64) throws(RemoteRdCoreError) -> Int {
        let code = datagram.withUnsafeBytes { raw in
            cmux_rd_session_push_datagram(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count, nowMicros)
        }
        return try RemoteRdCoreError.check(code)
    }

    /// Drops frames past their deadline in every stream.
    @discardableResult
    public func tick(nowMicros: UInt64) throws(RemoteRdCoreError) -> Int {
        try RemoteRdCoreError.check(cmux_rd_session_tick(handle, nowMicros))
    }

    /// The oldest complete access unit of any stream, with its stream.
    public func popAccessUnit(codec: RemoteVideoCodec) throws(RemoteRdCoreError) -> (stream: UInt16, unit: RemoteAccessUnit)? {
        var frame = CmuxRdFrame()
        var stream: UInt16 = 0
        guard try RemoteRdCoreError.check(cmux_rd_session_pop_frame(handle, &frame, &stream)) == 1 else { return nil }
        return (stream, RemoteRdCore.unit(frame, codec: codec))
    }

    /// The oldest queued transport message.
    public func popMessage() throws(RemoteRdCoreError) -> RemoteRdMessage? {
        var message = CmuxRdMessage()
        guard try RemoteRdCoreError.check(cmux_rd_session_pop_message(handle, &message)) == 1 else { return nil }
        return RemoteRdCore.message(message)
    }

    public func noteDecode(stream: UInt16, micros: UInt32) throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_session_note_decode(handle, stream, micros))
    }

    /// Asks the host for a keyframe of `stream` until one is released there.
    public func requestKeyframe(stream: UInt16) throws(RemoteRdCoreError) {
        _ = try RemoteRdCoreError.check(cmux_rd_session_request_keyframe(handle, stream))
    }

    /// Every feedback datagram due at `nowMicros` (any stream), framed for
    /// the carrier and ready to send in order.
    public func feedback(nowMicros: UInt64) throws(RemoteRdCoreError) -> [Data] {
        var out: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        // Bounded: each stream keeps at most a few messages' worth of arrivals.
        for _ in 0..<Self.maxFeedbackCalls {
            var length = 0
            let code = buffer.withUnsafeMutableBufferPointer { buf in
                cmux_rd_session_feedback(handle, nowMicros, buf.baseAddress, buf.count, &length)
            }
            if code < 0, RemoteRdCoreError(code: code) == .buffer {
                buffer = [UInt8](repeating: 0, count: length)
                continue
            }
            guard try RemoteRdCoreError.check(code) == 1 else { break }
            out.append(Data(buffer[0..<length]))
        }
        return out
    }

    private static let maxFeedbackCalls = 64

    /// When `tick` and `feedback` must run next (earliest of every stream),
    /// or nil when the session is unusable.
    public var nextDeadlineMicros: UInt64? {
        let value = cmux_rd_session_next_deadline_us(handle)
        return value == UInt64.max ? nil : value
    }

    /// The counters of `stream`.
    public func stats(stream: UInt16) throws(RemoteRdCoreError) -> RemoteRdStats {
        var raw = CmuxRdStats()
        _ = try RemoteRdCoreError.check(cmux_rd_session_stats(handle, stream, &raw))
        return RemoteRdStats(
            ackedFrame: raw.acked_frame,
            needRecovery: raw.need_recovery,
            framesReleased: raw.frames_released,
            framesLost: raw.frames_lost
        )
    }
}
