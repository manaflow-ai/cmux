public import Foundation
import CmuxNextCompat
import CmuxNextIPC
import CmuxNextWakeups

/// Input of a terminal view whose terminal is still being created (cx-wb5.78): the view of a pane
/// Cmd+D shows before the daemon replied. Each key goes to the daemon at once by the terminal id
/// the app minted for the creation; the daemon queues it and writes it after the commit, before any
/// later input. The app holds no keys.
///
/// Two ways carry the keys until the view's attach target is known (`targetKnown`):
/// - With a ``CreatingTerminalKeyStream`` (p05-ipc-153, `creating-input-streams-v1`): the create went as a
///   REQUEST frame naming stream S, which the daemon binds to the minted id when it takes the create
///   (cmux-tui pending_streams.rs, creating_input.rs). Each key is one INPUT frame on S: raw bytes behind a
///   16-byte header that names the key press's flow, no JSON, no base64, no request id and no reply, so it is
///   written without waiting for the daemon (``writeWithoutWaiting(_:)``). Chrome sends input the same way,
///   one-way messages on the widget's associated pipe, usable before the other end is bound
///   (third_party/blink/public/mojom/input/input_handler.mojom, `WidgetInputHandler.DispatchNonBlockingEvent`;
///   mojo/public/cpp/bindings/lib/multiplex_router.cc).
/// - Without one: `send {terminal_id}` (`terminal-input-while-creating-v1`). The view's writer awaits each
///   chunk's reply before the next goes out.
///
/// Once the target is known, the next chunk and every later one go by the attachment (`send {surface}` or the
/// view's own stream), which the daemon writes after the creating queue. The attachment may run on another
/// connection, which the daemon does not order against S, so the switch first waits until the daemon ran
/// every frame sent on S (``CreatingTerminalKeyStream/drain()``, one round trip per view, only when a key went
/// on S): then every key on S is in the creating queue or written, and no key can pass another. A key the
/// daemon refused on S comes back with every later key of S (`terminal-input-unclaimed`, the stream ends).
public nonisolated final class CreatingTerminalInput: CreatingTerminalInputSending {
    /// The host terminal id the creation minted (the id a give-back names).
    public let terminalID: String
    private let connection: DaemonConnection
    private let stream: (any CreatingTerminalKeyStream)?
    private let targetKnown: @Sendable () -> Bool
    private let probe: TypingLatencyProbe
    private let state = Mutex(Route())

    private struct Route {
        /// True once input goes by the attachment for good.
        var done = false
        /// A key went as an INPUT frame on the stream: the switch to the attachment drains the stream first.
        var sentOnStream = false
    }

    /// - Parameter stream: The create's input stream, when the create went as a REQUEST frame naming it.
    public convenience init(terminalID: String, connection: DaemonConnection,
                            stream: (any CreatingTerminalKeyStream)? = nil,
                            targetKnown: @escaping @Sendable () -> Bool) {
        self.init(terminalID: terminalID, connection: connection, stream: stream, probe: .shared,
                  targetKnown: targetKnown)
    }

    /// - Parameter probe: Names each key's press in its INPUT frame (the app's ``TypingLatencyProbe/shared``).
    init(terminalID: String, connection: DaemonConnection, stream: (any CreatingTerminalKeyStream)?,
         probe: TypingLatencyProbe, targetKnown: @escaping @Sendable () -> Bool) {
        self.terminalID = terminalID
        self.connection = connection
        self.stream = stream
        self.probe = probe
        self.targetKnown = targetKnown
    }

    /// True once input goes by the attachment for good: ``write(_:)`` would return false at once, so the
    /// caller sends without awaiting it.
    public var sendsByAttachment: Bool { state.withLock { $0.done } }

    /// Sends `data` by the terminal id; false when it must go by the attachment instead (the
    /// target is known, or the daemon refused the id: the attach queue keeps it, as before).
    public func write(_ data: Data) async -> Bool {
        if let sent = writeWithoutWaiting(data) { return sent }
        if targetKnown() {
            // Keys went on the stream: they run on the daemon before this chunk goes by the attachment.
            await stream?.drain()
            finish()
            return false
        }
        do {
            try await connection.sendTerminalInput(terminalID, bytes: data)
            return true
        } catch DaemonError.timedOut {
            // The daemon may hold the chunk: never send it twice (it gives back what it does not write).
            return true
        } catch {
            finish()
            return false
        }
    }

    /// Sends `data` now when that needs no wait: true when it went as INPUT frames on the stream, false when it
    /// goes by the attachment. Nil when ``write(_:)`` must be awaited: no stream (each chunk waits for its
    /// reply), or the target just became known after keys went on the stream (the switch drains it first).
    public func writeWithoutWaiting(_ data: Data) -> Bool? {
        let (done, sentOnStream) = state.withLock { ($0.done, $0.sentOnStream) }
        if done { return false }
        if targetKnown() {
            if stream != nil, sentOnStream { return nil }
            finish()
            return false
        }
        guard let stream else { return nil }
        return send(data, on: stream)
    }

    /// Writes `data` as INPUT frames on `stream`, in call order; the first names the press being sent, as a
    /// `send` line does. A frame the connection refused ended it, so the rest goes by the attachment of the
    /// next connection, as a refused `send` does.
    private func send(_ data: Data, on stream: any CreatingTerminalKeyStream) -> Bool {
        let flow = probe.openFlow
        var sent = true
        Self.forEachInputFrame(data, stream: stream.id, flow: flow) { frame in
            sent = stream.sendInputFrame(frame)
            return sent
        }
        guard sent else {
            finish()
            return false
        }
        state.withLock { $0.sentOnStream = true }
        if let flow { probe.mark(.socketSubmit, flow: flow) }
        return true
    }

    private func finish() {
        state.withLock { $0.done = true }
    }
}

/// The input stream a terminal create opened (p05-ipc-153): the id its REQUEST frame named, and the
/// connection that carries the stream's frames (``CreatingTerminalInput``).
public nonisolated protocol CreatingTerminalKeyStream: Sendable {
    /// The stream id the create's REQUEST frame named (never 0).
    var id: UInt16 { get }
    /// Writes one whole frame, in call order with this stream's earlier frames and after the create's REQUEST
    /// frame, without waiting on the socket. False once the connection ended or refused it.
    func sendInputFrame(_ frame: Data) -> Bool
    /// Returns once the daemon ran every frame sent on the stream before the call: a stream request on the
    /// stream (`send {terminal_id}` with no bytes), answered on the stream's sequence after them. Also returns
    /// when the stream or its connection ended, whose INPUT the daemon gave back.
    func drain() async
}

extension CreatingTerminalInput {
    /// INPUT (cmux-ipc frame.rs `FrameKind::Input`).
    static let inputFrameKind: UInt8 = 9

    /// Calls `body` with each INPUT frame of `data`, in order, until it returns false. Bytes past `maxPayload`
    /// go in further frames; only the first names the press (`flow`), since only one write echoes it.
    static func forEachInputFrame(_ data: Data, stream: UInt16, flow: UInt64? = nil,
                                  maxPayload: Int = Int(truncatingIfNeeded: FrameHeader.maxPayloadCap),
                                  _ body: (Data) -> Bool) {
        let size = max(1, maxPayload)
        var rest = data
        var press = flow
        while !rest.isEmpty {
            let payload = rest.prefix(size)
            guard body(inputFrame(payload, stream: stream, flow: press)) else { return }
            rest = rest.dropFirst(payload.count)
            press = nil
        }
    }

    /// One INPUT frame: magic 0xFF, kind 9, stream (LE u16), payload length (LE u32), flow id (LE u64, 0 for
    /// none), then `payload` (cmux-ipc frame.rs `FrameHeader`, `Aux::FlowId`). The daemon writes the bytes
    /// with that flow, so the echo of a key typed while the terminal starts names its press.
    static func inputFrame(_ payload: Data, stream: UInt16, flow: UInt64? = nil) -> Data {
        var frame = Data(capacity: FrameHeader.byteCount + payload.count)
        frame.append(FrameHeader.magic)
        frame.append(inputFrameKind)
        appendLittleEndian(stream, to: &frame)
        appendLittleEndian(UInt32(truncatingIfNeeded: payload.count), to: &frame)
        appendLittleEndian(flow ?? 0, to: &frame)
        frame.append(payload)
        return frame
    }

    private static func appendLittleEndian<Value: FixedWidthInteger & UnsignedInteger>(_ value: Value,
                                                                                      to data: inout Data) {
        for shift in stride(from: 0, to: Value.bitWidth, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}

/// Sends the input of a terminal still being created by its id (``CreatingTerminalInput``): the seam a
/// view's input drain uses, one chunk at a time.
public nonisolated protocol CreatingTerminalInputSending: Sendable {
    /// True once input goes by the attachment for good.
    var sendsByAttachment: Bool { get }
    /// Sends `data` by the terminal id; false when it must go by the attachment instead.
    func write(_ data: Data) async -> Bool
    /// Sends `data` now when that needs no wait (true: sent; false: by the attachment); nil when ``write(_:)``
    /// must be awaited.
    func writeWithoutWaiting(_ data: Data) -> Bool?
}

extension CreatingTerminalInputSending {
    /// Every chunk is awaited.
    public func writeWithoutWaiting(_ data: Data) -> Bool? { nil }
}
