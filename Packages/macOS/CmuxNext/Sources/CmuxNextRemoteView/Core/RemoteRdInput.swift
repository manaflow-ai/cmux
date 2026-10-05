#if CMUX_RD_FFI
import CCmuxRdFFI
public import Foundation

/// The viewer's input channel of one `cmux.rd/1` session, implemented by the
/// shared Rust core (cmux-rd-ffi `CmuxRdInput`, over cmux-rd-core
/// `InputSender`). Events go in; `Input` datagrams come out. Unacknowledged
/// events repeat in later packets (key and button releases until the host
/// acknowledges them); the host applies each event exactly once, in order.
///
/// No I/O, threads or timers inside: the owner sends `packets` at
/// `nextDeadlineMicros` and after every `send`, and hands each `InputAck`
/// datagram from `RemoteRdCore.popMessage` to `acknowledge`. Not
/// thread-safe: one actor owns an instance, like `RemoteRdCore`.
public nonisolated final class RemoteRdInput {
    /// The carrier this channel frames its packets for.
    public let carrier: RemoteRdCore.Carrier
    private let handle: OpaquePointer

    /// `resendMicros`: how long unacknowledged events wait before they go
    /// out again without new input (about one RTT). Nil only when the core
    /// cannot allocate a channel.
    public init?(carrier: RemoteRdCore.Carrier, resendMicros: UInt64 = 20_000) {
        guard let handle = cmux_rd_input_new(carrier.raw, resendMicros) else { return nil }
        self.carrier = carrier
        self.handle = handle
    }

    deinit {
        cmux_rd_input_free(handle)
    }

    /// Queues one event and returns its sequence number. Text longer than
    /// `RemoteInputEvent.maxTextBytes` must be split first
    /// (`RemoteInputEvent.textEvents`); empty or too long text throws `.invalid`.
    @discardableResult
    public func send(_ event: RemoteInputEvent) throws(RemoteRdCoreError) -> UInt32 {
        var raw = CmuxRdInputEvent()
        var seq: UInt32 = 0
        let code: Int32
        switch event {
        case let .key(usage, down):
            raw.kind = UInt32(CMUX_RD_INPUT_KEY)
            raw.usage = usage
            raw.down = down ? 1 : 0
            code = cmux_rd_input_push(handle, &raw, &seq)
        case let .pointer(x, y):
            raw.kind = UInt32(CMUX_RD_INPUT_POINTER)
            raw.x = x
            raw.y = y
            code = cmux_rd_input_push(handle, &raw, &seq)
        case let .button(button, down):
            raw.kind = UInt32(CMUX_RD_INPUT_BUTTON)
            raw.button = button.rawValue
            raw.down = down ? 1 : 0
            code = cmux_rd_input_push(handle, &raw, &seq)
        case let .scroll(dx, dy, precise):
            raw.kind = UInt32(CMUX_RD_INPUT_SCROLL)
            raw.dx = dx
            raw.dy = dy
            raw.precise = precise ? 1 : 0
            code = cmux_rd_input_push(handle, &raw, &seq)
        case let .text(text):
            raw.kind = UInt32(CMUX_RD_INPUT_TEXT)
            var utf8 = Array(text.utf8)
            code = utf8.withUnsafeMutableBufferPointer { buffer in
                raw.text = UnsafePointer(buffer.baseAddress)
                raw.text_len = buffer.count
                return cmux_rd_input_push(handle, &raw, &seq)
            }
        }
        _ = try RemoteRdCoreError.check(code)
        return seq
    }

    /// Applies an `InputAck` datagram (a `.datagram` message from
    /// `RemoteRdCore.popMessage`, header included). Throws `.invalid` for any
    /// other datagram, so the owner can offer each datagram message here first.
    public func acknowledge(datagram: Data) throws(RemoteRdCoreError) {
        let code = datagram.withUnsafeBytes { raw in
            cmux_rd_input_ack(handle, raw.baseAddress?.assumingMemoryBound(to: UInt8.self), raw.count)
        }
        _ = try RemoteRdCoreError.check(code)
    }

    /// Every input datagram due at `nowMicros`, framed for the carrier and
    /// ready to send in order (zero or more).
    public func packets(nowMicros: UInt64) throws(RemoteRdCoreError) -> [Data] {
        var out: [Data] = []
        var buffer = [UInt8](repeating: 0, count: Int(CMUX_RD_INPUT_PACKET_MAX))
        for _ in 0..<Self.maxPacketCalls {
            var length = 0
            let code = buffer.withUnsafeMutableBufferPointer { buf in
                cmux_rd_input_packet(handle, nowMicros, buf.baseAddress, buf.count, &length)
            }
            guard try RemoteRdCoreError.check(code) == 1 else { break }
            out.append(Data(buffer[0..<length]))
        }
        return out
    }

    /// Bounded: the core queues new events in packets of at most 32, and a
    /// burst of typing produces a handful; the rest go out at the next deadline.
    private static let maxPacketCalls = 64

    /// When `packets` must run next, or nil when nothing waits (or the
    /// channel is unusable). A value at or before now means at once.
    public var nextDeadlineMicros: UInt64? {
        let value = cmux_rd_input_next_deadline_us(handle)
        return value == UInt64.max ? nil : value
    }
}
#endif
