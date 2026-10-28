import Foundation

/// Client-minted attach streams on this connection (attach-streams-v1): the reader routes each
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
    func bindAttachStream(_ handle: AttachStreamHandle, _ sink: AttachStreamSink) -> Bool {
        state.withLock { $0.attachStreams.bind(handle, sink) }
    }

    /// Drops the handle's later items; its id stays taken until its `stream-end` or its `cancel-stream` reply.
    /// True when it was not cancelled yet, so a `cancel-stream` is due.
    func cancelAttachStream(_ handle: AttachStreamHandle) -> Bool {
        state.withLock { $0.attachStreams.cancel(handle) }
    }

    /// Frees an id the daemon sends nothing more for.
    func releaseAttachStream(_ handle: AttachStreamHandle) {
        state.withLock { $0.attachStreams.release(handle) }
    }

    /// Ids taken on this connection (tests, diagnostics).
    var attachStreamCount: Int { state.withLock { $0.attachStreams.count } }

    /// Reader thread. Routes a tagged item to its stream: the item runs on the ``lane`` in wire order,
    /// and the stream's reader wait is returned for the reader to run after the line. Nil on a connection that never
    /// minted a stream, whose line the control path routes. Once this side minted a stream, an item for an id it no
    /// longer holds is dropped, never routed as a control event.
    func routeAttachStream(_ stream: UInt16, event: String, line: Data) -> AttachStreamRouted? {
        let ended = event == AttachStreamTable.endEvent
        switch state.withLock({ $0.attachStreams.route(stream, ended: ended) }) {
        case .deliver(let sink):
            recorder?.lineRead(ended ? .streamEnd : .streamItem)
            let item: AttachStreamDelivery = ended ? .end(line: line) : .event(name: event, line: line)
            let deliver = sink.deliver
            lane.post(ended ? .heavy : sink.dispatch.weigh(event, line), bytes: line.count) { deliver(item) }
            return AttachStreamRouted(readerWait: sink.dispatch.readerWait)
        case .dropped:
            recorder?.lineRead(.ignored)
            return AttachStreamRouted(readerWait: nil)
        case .unknown:
            return nil
        }
    }

    /// Reader thread, once the connection ended: no id is minted again, and the open streams are returned, to
    /// learn it on the lane after their last items.
    func takeAttachStreams() -> [AttachStreamSink] {
        state.withLock { $0.attachStreams.endAll() }
    }
}

/// An attach stream item the reader routed (``LineTransport/routeAttachStream(_:event:line:)``).
struct AttachStreamRouted: Sendable {
    /// The stream's wait for its view, which the reader runs after the line (``EventDispatch/readerWait``).
    var readerWait: (@Sendable () -> Void)?
}
