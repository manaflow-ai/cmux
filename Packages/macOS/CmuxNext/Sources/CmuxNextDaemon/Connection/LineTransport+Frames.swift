import CmuxNextIPC
import Foundation

/// The framed half of the transport (p05-ipc-092): what the handshake granted, and the reader's routing of
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

    /// What goes on the wire for request `id`: a REQUEST frame when `framing` frames `cmd`, on `stream` (0, or
    /// the stream an opener opens), else its line. `framed` tells which.
    static func message(_ payload: Data, id: UInt64, cmd: String, framing: FramedRequests?,
                        stream: UInt16 = 0) -> (bytes: Data, framed: Bool) {
        if let method = framing?.method(for: cmd, bodyBytes: payload.count) {
            return (FramedRequests.requestFrame(payload, requestID: id, method: method, stream: stream), true)
        }
        var line = payload
        line.append(0x0A)
        return (line, false)
    }

    /// Routes one message the reader cut: a line by its fields, a frame by its header. Returns why it is a bad
    /// message, which ends the connection, or nil.
    func dispatch(_ message: FrameReader.Message, decoder: WireDecoder, outputStream: DaemonWireStats.Recorder?,
                  onEvent: CausedEventHandler) -> String? {
        switch message {
        case .json(let bytes):
            // An empty line carries nothing.
            guard !bytes.isEmpty else { return nil }
            outputStream?.outputCopied(2 * bytes.count)  // out of the reader as the line, then into its Data
            handle(bytes, decoder: decoder, onEvent: onEvent)
            return nil
        case .frame(let frame):
            return handle(frame, decoder: decoder)
        }
    }

    /// Routes one frame inside the reader's hang scope, as a line is; returns why it is a bad message, or nil.
    func handle(_ frame: Frame, decoder: WireDecoder) -> String? {
        guard let hangWatched else { return route(frame: frame, decoder: decoder) }
        return hangWatched.run { route(frame: frame, decoder: decoder) }
    }

    /// Routes one frame on the reader thread: a REPLY or ERROR, matched by its request id. It comes on the
    /// stream its request named: 0, or for a stream opener the stream it opened (frame_dispatch.rs
    /// `FrameCall::reply_header`), whose `stream-end` may have freed the id already when the open failed.
    /// Anything else is a bad message (its reason returned), which closes the connection, as the daemon closes
    /// on a frame it cannot route (frame_dispatch.rs, `UnroutedKind`).
    func route(frame: Frame, decoder: WireDecoder) -> String? {
        let header = frame.header
        let ok = header.kind == FramedRequests.replyKind
        guard ok || header.kind == FramedRequests.errorKind else {
            return "unrouted frame kind \(header.kind) on stream \(header.stream)"
        }
        let call = FramedRequests.call(of: header)
        let line = Data(frame.payload)
        // An ERROR's body is decoded once, here: its fields fail the waiter.
        let failure = ok ? nil : try? decoder.decode(Envelope.self, from: line)
        let id = state.withLock { FramedRequests.requestID(low: call.requestID, next: $0.nextID) }
        var envelope = failure ?? Envelope(id: nil, ok: nil, event: nil, type: nil, streamID: nil, cause: nil)
        (envelope.id, envelope.ok) = (id, ok)
        resolveReply(envelope, line: line, parsed: failure != nil, decoder: decoder)
        return nil
    }
}
