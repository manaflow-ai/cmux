import CmuxNextIPC
import Foundation

/// The framed half of the transport (p05-ipc-092): what the handshake granted, and the reader's routing of
/// REPLY, ERROR and stream EVENT frames. Requests become frames in ``LineTransport/submit(_:deadline:framed:_:)``.
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
    /// message, which ends the connection, or nil. After a handled line, `waitForConsumer` runs outside the
    /// line's hang scope (``LineTransport/start(onCausedEvent:waitForConsumer:onClose:)``).
    func dispatch(_ message: FrameReader.Message, decoder: WireDecoder, outputStream: DaemonWireStats.Recorder?,
                  onEvent: CausedEventHandler, waitForConsumer: (@Sendable () -> Void)?) -> String? {
        switch message {
        case .json(let bytes):
            // An empty line carries nothing.
            guard !bytes.isEmpty else { return nil }
            outputStream?.outputCopied(2 * bytes.count)  // out of the reader as the line, then into its Data
            handle(bytes, decoder: decoder, onEvent: onEvent)
            waitForConsumer?()
            return nil
        case .frame(let frame):
            if let unrouted = handle(frame, decoder: decoder, onEvent: onEvent) { return unrouted }
            // A stream item is an event, so its consumer may park the reader as a line's does.
            if frame.header.kind == Self.eventFrameKind { waitForConsumer?() }
            return nil
        }
    }

    /// Routes one frame inside the reader's hang scope, as a line is; returns why it is a bad message, or nil.
    func handle(_ frame: Frame, decoder: WireDecoder, onEvent: CausedEventHandler) -> String? {
        guard let hangWatched else { return route(frame: frame, decoder: decoder, onEvent: onEvent) }
        return hangWatched.run { route(frame: frame, decoder: decoder, onEvent: onEvent) }
    }

    /// Routes one frame on the reader thread by its header alone. REPLY and ERROR frames on stream 0 answer
    /// requests; an EVENT frame on the client stream of an open control stream is that stream's item
    /// (``routeStreamItem(_:onEvent:)``). Anything else is a bad message (its reason returned), which closes
    /// the connection, as the daemon closes on a frame it cannot route (frame_dispatch.rs, `UnroutedKind`).
    func route(frame: Frame, decoder: WireDecoder, onEvent: CausedEventHandler) -> String? {
        let header = frame.header
        if header.kind == Self.eventFrameKind, header.stream != 0 {
            return routeStreamItem(frame, onEvent: onEvent)
        }
        let ok = header.kind == FramedRequests.replyKind
        guard header.stream == 0, ok || header.kind == FramedRequests.errorKind else {
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

    /// An EVENT frame on the client stream of a control stream (`session.events` opened with `stream`,
    /// p05-ipc-145) is that stream's item: counted with the stream-0 events and handed to `onEvent` as the
    /// stream line it carries, with no envelope scan or decode (Mojo routes a message by its header's
    /// interface id, mojo/public/cpp/bindings/lib/multiplex_router.cc `Accept`). On an id no open stream
    /// holds it is a bad message: the daemon writes a stream's items before its `stream_end`, and the id is
    /// freed only when that end is read.
    func routeStreamItem(_ frame: Frame, onEvent: CausedEventHandler) -> String? {
        let stream = frame.header.stream
        let index = state.withLock { state -> UInt64? in
            guard state.controlFrameStreams[stream] != nil else { return nil }
            state.eventCount += 1
            return state.eventCount
        }
        guard let index else { return "event frame on stream \(stream), which no open stream holds" }
        recorder?.lineRead(.streamItem)
        onEvent(Self.streamEvent, Data(frame.payload), index, nil)
        return nil
    }
}
