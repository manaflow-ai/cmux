public import Foundation
import CmuxNextCompat
import CmuxNextIPC

/// Input of a terminal view whose terminal is still being created (cx-wb5.78): the view of a pane
/// Cmd+D shows before the daemon replied. Each key goes to the daemon at once by the terminal id
/// the app minted for the creation; the daemon queues it and writes it after the commit, before any
/// later input. The app holds no keys.
///
/// Two ways carry the keys:
/// - With a ``CreatingTerminalKeyStream`` (p05-ipc-153): the create went as a REQUEST frame naming
///   stream S, which the daemon binds to the minted id when it takes the create (pending_streams.rs,
///   creating_input.rs).
///   Each key is one INPUT frame on S: raw bytes behind a 16-byte header, no JSON, no base64, no request
///   id and no reply, so ``write(_:)`` never waits for the daemon. Keys stay on S for the view's life: the
///   view's `attach-surface` on S takes the stream over on the daemon, and a key sent on S after the
///   terminal is live is written to it there, so no key can pass another whichever way the view attaches.
///   Chrome sends input the same way, one-way messages on the widget's associated pipe, usable before the
///   other end is bound (third_party/blink/public/mojom/input/input_handler.mojom,
///   `WidgetInputHandler.DispatchNonBlockingEvent`; mojo/public/cpp/bindings/lib/multiplex_router.cc).
/// - Without one: `send {terminal_id}` (`terminal-input-while-creating-v1`). The view's writer awaits each
///   chunk's reply before the next goes out. Once the view's attach target is known (`targetKnown`), the
///   next chunk goes by the attachment (`send {surface}`), which the daemon writes after the queue.
public nonisolated final class CreatingTerminalInput: CreatingTerminalInputSending {
    /// The host terminal id the creation minted (the id a give-back names).
    public let terminalID: String
    private let connection: DaemonConnection
    private let stream: (any CreatingTerminalKeyStream)?
    private let targetKnown: @Sendable () -> Bool
    /// True once input goes by the attachment for good.
    private let done = Mutex(false)

    /// - Parameter stream: The create's input stream, when the create went as a REQUEST frame naming it.
    public init(terminalID: String, connection: DaemonConnection, stream: (any CreatingTerminalKeyStream)? = nil,
                targetKnown: @escaping @Sendable () -> Bool) {
        self.terminalID = terminalID
        self.connection = connection
        self.stream = stream
        self.targetKnown = targetKnown
    }

    /// True once input goes by the attachment for good: ``write(_:)`` would return false at once, so the
    /// caller sends without awaiting it.
    public var sendsByAttachment: Bool { done.withLock { $0 } }

    /// Sends `data` by the terminal id; false when it must go by the attachment instead (the
    /// target is known, or the daemon refused the id: the attach queue keeps it, as before).
    public func write(_ data: Data) async -> Bool {
        if done.withLock({ $0 }) { return false }
        if let stream { return send(data, on: stream) }
        if targetKnown() {
            done.withLock { $0 = true }
            return false
        }
        do {
            try await connection.sendTerminalInput(terminalID, bytes: data)
            return true
        } catch DaemonError.timedOut {
            // The daemon may hold the chunk: never send it twice (it gives back what it does not write).
            return true
        } catch {
            done.withLock { $0 = true }
            return false
        }
    }

    /// Writes `data` as INPUT frames on `stream`, in call order. A frame the connection refused ended it, so
    /// the rest goes by the attachment of the next connection, as a refused `send` does.
    private func send(_ data: Data, on stream: any CreatingTerminalKeyStream) -> Bool {
        var sent = true
        Self.forEachInputFrame(data, stream: stream.id) { frame in
            sent = stream.sendInputFrame(frame)
            return sent
        }
        if !sent { done.withLock { $0 = true } }
        return sent
    }
}

/// The input stream a terminal create opened (p05-ipc-153): the id its REQUEST frame named, and the
/// connection that carries the stream's frames (``CreatingTerminalInput``).
public nonisolated protocol CreatingTerminalKeyStream: Sendable {
    /// The stream id the create's REQUEST frame named (never 0).
    var id: UInt16 { get }
    /// Writes one whole frame at input priority, in call order with this stream's earlier frames, without
    /// waiting on the socket. False once the connection ended or refused it.
    func sendInputFrame(_ frame: Data) -> Bool
}

extension CreatingTerminalInput {
    /// INPUT (cmux-ipc frame.rs `FrameKind::Input`).
    static let inputFrameKind: UInt8 = 9

    /// Calls `body` with each INPUT frame of `data`, in order, until it returns false. Bytes past `maxPayload`
    /// go in further frames.
    static func forEachInputFrame(_ data: Data, stream: UInt16,
                                  maxPayload: Int = Int(truncatingIfNeeded: FrameHeader.maxPayloadCap),
                                  _ body: (Data) -> Bool) {
        let size = max(1, maxPayload)
        var rest = data
        while !rest.isEmpty {
            let payload = rest.prefix(size)
            guard body(inputFrame(payload, stream: stream)) else { return }
            rest = rest.dropFirst(payload.count)
        }
    }

    /// One INPUT frame: magic 0xFF, kind 9, stream (LE u16), payload length (LE u32), flow id (LE u64, 0: a
    /// queued key's echo is not traced), then `payload` (cmux-ipc frame.rs `FrameHeader`, `Aux::FlowId`).
    static func inputFrame(_ payload: Data, stream: UInt16) -> Data {
        var frame = Data(capacity: FrameHeader.byteCount + payload.count)
        frame.append(FrameHeader.magic)
        frame.append(inputFrameKind)
        appendLittleEndian(stream, to: &frame)
        appendLittleEndian(UInt32(truncatingIfNeeded: payload.count), to: &frame)
        appendLittleEndian(UInt64.zero, to: &frame)
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
/// view's input drain awaits, one chunk at a time.
public nonisolated protocol CreatingTerminalInputSending: Sendable {
    /// True once input goes by the attachment for good.
    var sendsByAttachment: Bool { get }
    /// Sends `data` by the terminal id; false when it must go by the attachment instead.
    func write(_ data: Data) async -> Bool
}
