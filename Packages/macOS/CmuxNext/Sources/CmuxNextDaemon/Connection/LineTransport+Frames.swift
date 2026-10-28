import CmuxNextIPC
import Foundation

/// The framed half of the transport: what the handshake granted, and the reader's routing of
/// REPLY and ERROR frames. Requests become frames in ``LineTransport/submit(_:deadline:framed:_:)``.
extension LineTransport {
    /// What the handshake granted; ``DaemonWireGrants/linesOnly`` until it ends and on a daemon that offers
    /// no framed IPC.
    var wireGrants: DaemonWireGrants { state.withLock { $0.grants } }

    /// Lets the reader cut 0xFF frames. The handshake calls it before it writes the `set-client-info` that
    /// echoes `ipc-frames-v2`, so no frame the daemon may send after its grant meets a reader that refuses it.
    func acceptFrames() {
        state.withLock { $0.acceptsFrames = true }
    }

    /// Whether the reader cuts frames (read by the reader thread once per read until it does).
    var acceptsFrames: Bool { state.withLock { $0.acceptsFrames } }

    /// Records what the handshake got. With frames granted, typed requests of the daemon's framed methods go
    /// as REQUEST frames (``FramedRequests``).
    func adopt(_ granted: WireNegotiation.Granted) {
        state.withLock { state in
            state.grants = granted.grants
            state.framing = granted.framing
        }
    }

    /// What goes on the wire for request `id`: a REQUEST frame when `framing` frames `cmd`, else its line.
    static func message(_ payload: Data, id: UInt64, cmd: String, framing: FramedRequests?) -> Data {
        if let method = framing?.method(for: cmd, bodyBytes: payload.count) {
            return FramedRequests.requestFrame(payload, requestID: id, method: method)
        }
        var line = payload
        line.append(0x0A)
        return line
    }

    /// Routes one message the reader cut: a line by its fields, a frame by its header. Returns why it is a bad
    /// message, which ends the connection, or nil. After a handled message the reader waits, outside its hang
    /// scope, while its ``lane``'s backlog is full and then, after a line, as `events` asks, or after an attach
    /// stream's item as its stream asks (``EventDispatch/readerWait``, ``LineTransport/start(dispatch:onCausedEvent:onClose:)``).
    func dispatch(_ message: FrameReader.Message, decoder: WireDecoder, outputStream: DaemonWireStats.Recorder?,
                  events: EventDispatch, onEvent: @escaping CausedEventHandler) -> String? {
        switch message {
        case .json(let bytes):
            // An empty line carries nothing.
            guard !bytes.isEmpty else { return nil }
            outputStream?.outputCopied(2 * bytes.count)  // out of the reader as the line, then into its Data
            let stream = handle(bytes, decoder: decoder, dispatch: events, onEvent: onEvent)
            lane.waitForRoom()
            if let stream {
                // An attach stream's item: its view's wait, not the control consumer's.
                stream.readerWait?()
            } else {
                events.readerWait?()
            }
            return nil
        case .frame(let frame):
            let unrouted = handle(frame, decoder: decoder)
            lane.waitForRoom()
            return unrouted
        }
    }

    /// Routes one frame inside the reader's hang scope, as a line is; returns why it is a bad message, or nil.
    func handle(_ frame: Frame, decoder: WireDecoder) -> String? {
        guard let hangWatched else { return route(frame: frame, decoder: decoder) }
        return hangWatched.run { route(frame: frame, decoder: decoder) }
    }

    /// Routes one frame on the reader thread; its waiter resumes on the ``lane``. Only REPLY and ERROR frames on
    /// stream 0 come before this connection opens a stream; anything else is a bad message (its reason returned),
    /// which closes the connection, as the daemon closes on a frame it cannot route (frame_dispatch.rs, `UnroutedKind`).
    func route(frame: Frame, decoder: WireDecoder) -> String? {
        let header = frame.header
        let ok = header.kind == FramedRequests.replyKind
        guard header.stream == 0, ok || header.kind == FramedRequests.errorKind else {
            return "unrouted frame kind \(header.kind) on stream \(header.stream)"
        }
        let call = FramedRequests.call(of: header)
        let line = Data(frame.payload)
        let id = state.withLock { FramedRequests.requestID(low: call.requestID, next: $0.nextID) }
        // An ERROR's body is decoded once, on the lane, for the fields that fail its waiter (the
        // reader decodes nothing a handler reads).
        let envelope = Envelope(id: id, ok: ok, event: nil, type: nil, streamID: nil, cause: nil)
        resolveReply(envelope, line: line, parsed: false, decoder: decoder)
        return nil
    }
}
