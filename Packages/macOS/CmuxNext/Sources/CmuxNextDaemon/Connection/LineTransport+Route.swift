import CmuxNextIPC
import Foundation

extension LineTransport {
    /// The reader's next whole message (nil: it needs more bytes), or the bad message that ends the connection.
    static func nextMessage(_ reader: inout FrameReader) -> Result<FrameReader.Message?, BadMessage> {
        Result { () throws(BadMessage) -> FrameReader.Message? in try reader.next() }
    }

    /// Routes one line by its fields, on the reader thread. ``LineRouteScan`` reads them from the reader's
    /// bytes, so a reply or an event is parsed once, by its reader. Only a line the scan cannot read is decoded
    /// as an ``Envelope`` here; a reply that is not `ok:true` is decoded once for its error fields, on the lane.
    /// What a line causes (its handler, its waiter's resumption) goes to ``lane`` in wire order (p05-ipc-144):
    /// the reader counts and routes, and decodes nothing a handler reads.
    func route<Line: RandomAccessCollection<UInt8>>(_ bytes: Line, decoder: WireDecoder, dispatch: EventDispatch,
                                                    onEvent: @escaping CausedEventHandler)
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
                // A resource stream's item is bulk: its handler decodes it.
                return lane.post(.heavy, bytes: line.count) { handler(streamID, line) }
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
            let cause = envelope.cause
            lane.post(dispatch.weigh(name, line), bytes: line.count) { onEvent(name, line, index, cause) }
            dispatch.readerWait?()
            return
        }
        guard envelope.ok != nil || envelope.id != nil else {
            recorder?.lineRead(.ignored)
            return
        }
        let routed: (UInt64, PendingRequest)? = state.withLock { state in
            guard let id = envelope.id ?? state.pending.oldestID(), let entry = state.pending.remove(id: id) else { return nil }
            removeDeadline(&state, id: id)
            return (state.eventCount, entry)
        }
        guard let (barrier, entry) = routed else {
            recorder?.lineRead(.droppedReply)
            return
        }
        let waiter = entry.waiter
        if let sent = entry.sent { recorder?.replied(sent) }
        recorder?.lineRead(waiter.replyKind(ok: envelope.ok == true))
        if envelope.ok == true {
            if case .reply(_, let slot) = waiter {
                // Light: resolving decodes nothing; its awaiter decodes the line.
                let response = Response(line: line, eventBarrier: barrier, recorder: recorder)
                lane.post(.light, bytes: line.count) { slot.resolve(.success(response)) }
            }
            return
        }
        guard waiter.failure != nil else { return }
        // The error's fields: this line's one parse (its waiter reads no data from it), on the lane.
        let routing = envelope
        lane.post(.heavy, bytes: line.count) {
            let failure = decoded ? routing : (try? decoder.decode(Envelope.self, from: line)) ?? routing
            waiter.failure?(DaemonError.command(cmd: waiter.cmd, message: failure.error ?? "unknown error", code: failure.errorCode,
                                                details: failure.errorDetails, retryable: failure.retryable))
        }
    }
}
