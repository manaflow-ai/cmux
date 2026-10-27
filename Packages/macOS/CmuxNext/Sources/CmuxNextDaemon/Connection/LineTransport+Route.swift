import CmuxNextIPC
import Foundation

extension LineTransport {
    /// The reader's next whole message (nil: it needs more bytes), or the bad message that ends the connection.
    static func nextMessage(_ reader: inout FrameReader) -> Result<FrameReader.Message?, BadMessage> {
        Result { () throws(BadMessage) -> FrameReader.Message? in try reader.next() }
    }

    /// Routes one line by its fields, on the reader thread. ``LineRouteScan`` reads them from the reader's
    /// bytes, so a reply or an event is parsed once, by its reader. Only a line the scan cannot read is decoded
    /// as an ``Envelope`` here, and a reply that is not `ok:true`, once, for its error fields.
    func route<Line: RandomAccessCollection<UInt8>>(_ bytes: Line, decoder: WireDecoder, onEvent: CausedEventHandler)
    where Line.Index == Int {
        let line = Data(bytes)
        let envelope: Envelope
        var decoded = false
        if let scanned = LineRouteScan(bytes) {
            envelope = scanned.envelope
        } else if let full = try? decoder.decode(Envelope.self, from: line) {
            envelope = full
            decoded = true
        } else {
            recorder?.lineRead(.ignored)
            return
        }
        // A v2 stream line goes to the stream handler of a dedicated
        // connection (`SessionJournalRead`); on the control connection it
        // travels with the raw events, in socket order (`session.events`).
        let streamed = envelope.type == "stream_item" || envelope.type == "stream_end"
        let streamKind: DaemonWireStats.FrameKind = envelope.type == "stream_end" ? .streamEnd : .streamItem
        if streamed, let streamID = envelope.streamID {
            let streamRoute = state.withLock { state -> StreamRoute in
                if state.controlStreams.contains(streamID) {
                    if envelope.type == "stream_end" { state.controlStreams.remove(streamID) }
                    return .control
                }
                if let handler = state.streamHandler { return .handler(handler) }
                return .unrouted
            }
            switch streamRoute {
            case .control: break
            case .handler(let handler):
                recorder?.lineRead(streamKind)
                return handler(streamID, line)
            case .unrouted:
                recorder?.lineRead(.ignored)
                return
            }
        }
        if let name = streamed ? Self.streamEvent : envelope.event {
            let index = state.withLock { state -> UInt64 in
                if name == "daemon-shutdown" { state.sawShutdown = true }
                state.eventCount += 1
                return state.eventCount
            }
            recorder?.lineRead(streamed ? streamKind : .event)
            onEvent(name, line, index, envelope.cause)
            return
        }
        guard envelope.ok != nil || envelope.id != nil else {
            recorder?.lineRead(.ignored)
            return
        }
        let routed: (id: UInt64, barrier: UInt64, entry: PendingRequest)? = state.withLock { state in
            guard let id = envelope.id ?? state.pending.oldestID(), let entry = state.pending.remove(id: id) else { return nil }
            removeDeadline(&state, id: id)
            return (id: id, barrier: state.eventCount, entry: entry)
        }
        guard let (id, barrier, entry) = routed else {
            recorder?.lineRead(.droppedReply)
            return
        }
        let waiter = entry.waiter
        // Before the reply resolves its slot, which ends the request's slice.
        receiveRequestFlow(id: id, waiter: waiter)
        if let sent = entry.sent { recorder?.replied(sent) }
        recorder?.lineRead(waiter.replyKind(ok: envelope.ok == true))
        if envelope.ok == true {
            if case .reply(_, let slot) = waiter {
                slot.resolve(.success(Response(line: line, eventBarrier: barrier, recorder: recorder)))
            }
            return
        }
        guard let fail = waiter.failure else { return }
        // The error's fields: this line's one parse (its waiter reads no data from it).
        let failure = decoded ? envelope : (try? decoder.decode(Envelope.self, from: line)) ?? envelope
        fail(DaemonError.command(cmd: waiter.cmd, message: failure.error ?? "unknown error", code: failure.errorCode,
                                 details: failure.errorDetails, retryable: failure.retryable))
    }
}
