import Foundation

/// Client-minted attach streams on this connection (attach-streams-v1, p05-ipc-095): the reader routes each
/// item by the `stream` it carries to the sink its view bound before the open went out, and never counts it
/// as a stream-0 event (``routedEventCount``).
extension LineTransport {
    /// Mints a stream id for a view that is about to open; bind its sink before the open request is sent.
    func reserveAttachStream() throws(DaemonError) -> AttachStreamHandle {
        let minted = state.withLock { state -> Result<AttachStreamHandle, DaemonError> in
            if let reason = state.closed { return .failure(Self.closedError(reason)) }
            guard let handle = state.attachStreams.reserve() else {
                return .failure(state.attachStreams.closed
                    ? .connectionClosed(reason: "lost")
                    : .command(cmd: "attach-surface", message: "every stream id is taken", code: "stream_in_use"))
            }
            return .success(handle)
        }
        return try minted.get()
    }

    /// Routes the handle's items to `sink` from now on. False when the connection ended meanwhile.
    func bindAttachStream(_ handle: AttachStreamHandle, _ sink: @escaping AttachStreamSink) -> Bool {
        state.withLock { $0.attachStreams.bind(handle, sink) }
    }

    /// Drops the handle's later items; its id stays taken until its `stream-end`. True when the stream was
    /// still open, so a `cancel-stream` is due.
    func cancelAttachStream(_ handle: AttachStreamHandle) -> Bool {
        state.withLock { $0.attachStreams.cancel(handle) }
    }

    /// Frees an id the daemon sends nothing more for.
    func releaseAttachStream(_ handle: AttachStreamHandle) {
        state.withLock { $0.attachStreams.release(handle) }
    }

    /// Ids taken on this connection (tests, diagnostics).
    var attachStreamCount: Int { state.withLock { $0.attachStreams.count } }

    /// Reader thread. Hands a tagged item to its stream; false on a connection that never minted one, whose
    /// line the control path routes. Once this side minted a stream, an item for an id it no longer holds is
    /// dropped, never routed as a control event.
    func routeAttachStream(_ stream: UInt16, event: String, line: Data) -> Bool {
        let ended = event == AttachStreamTable.endEvent
        switch state.withLock({ $0.attachStreams.route(stream, ended: ended) }) {
        case .deliver(let sink):
            recorder?.lineRead(ended ? .streamEnd : .streamItem)
            sink(ended ? .end(line: line) : .event(name: event, line: line))
            return true
        case .dropped:
            recorder?.lineRead(.ignored)
            return true
        case .unknown:
            return false
        }
    }

    /// Reader thread, once the connection ended: every open stream learns it, and no id is minted again.
    func endAttachStreams(_ reason: TransportCloseReason) {
        let sinks = state.withLock { $0.attachStreams.endAll() }
        for sink in sinks { sink(.lost(reason)) }
    }
}
