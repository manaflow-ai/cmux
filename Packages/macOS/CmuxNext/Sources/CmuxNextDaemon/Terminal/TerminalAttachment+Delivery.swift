import os

extension TerminalAttachment {
    /// How a view's events reach it when its consumer falls 8 MiB behind.
    enum Delivery: Sendable, Equatable {
        /// Its own attach connection (the legacy path): the reader thread parks, the daemon's attach
        /// mailbox overflows and ends the stream with `overflow`, and the view reattaches.
        case ownConnection
        /// Stream `stream` on the machine's shared connection (`attach-streams-v1`, p05-ipc-095 mints the
        /// id): the reader never waits, so a stopped view delays no other stream and no control reply.
        /// The view drops its output and asks for one fresh READY (`snapshot-request`) instead.
        case sharedStream(stream: UInt16)
    }

    /// The queue's policy for `delivery`. A shared stream's resync asks the host for one READY + history
    /// on its own stream, so another view of the surface on the connection gets no READY it did not
    /// ask for. Dropped output is a `gap`, the wire's reason for missing output (the daemon accepts only
    /// its four reasons).
    nonisolated static func backpressure(
        for delivery: Delivery, transport: LineTransport, surface: @escaping @Sendable () -> SurfaceID
    ) -> TerminalEventQueue.Backpressure {
        switch delivery {
        case .ownConnection:
            return .parkReader
        case .sharedStream(let stream):
            let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.attach")
            return .dropAndResync({ completion in
                let request = SnapshotRequestRequest(surface: surface(), reason: .gap, stream: stream)
                Self.requestResync(request, on: transport, logger: logger, completion: completion)
            })
        }
    }

    /// Sends `request` and reports the daemon's answer to `completion`; returns at once, so the reader
    /// thread that overflowed never waits. An error reply, a missed deadline or a closed connection is
    /// ``TerminalEventQueue/ResyncOutcome/failed``: no READY will come.
    nonisolated static func requestResync(
        _ request: SnapshotRequestRequest, on transport: LineTransport, logger: Logger,
        completion: @escaping @Sendable (TerminalEventQueue.ResyncOutcome) -> Void
    ) {
        // task-owner: ends with the reply, its deadline or the connection's close (LineTransport fails every
        // pending request); the queue ignores an answer to a request a READY already answered.
        Task {
            do {
                let reply = try await DaemonConnection.perform(request, on: transport)
                completion(Self.resyncOutcome(reply))
            } catch {
                logger.error("snapshot-request for a resync failed: \(String(describing: error), privacy: .public)")
                completion(.failed)
            }
        }
    }

    /// What the queue does with the daemon's answer: a throttled request waits `retry_after_ms` (the
    /// daemon's 500 ms interval when it names none) and goes out again.
    nonisolated static func resyncOutcome(_ reply: SnapshotRequestRequest.Response) -> TerminalEventQueue.ResyncOutcome {
        switch reply.status {
        case .accepted, .collapsed: .accepted
        case .snapshotThrottled: .throttled(retryAfter: .milliseconds(max(reply.retryAfterMs ?? 500, 1)))
        }
    }

    /// Sends `request` with no reply on `transport`; any thread, never waits.
    nonisolated static func fireAndForget<R: DaemonRequest>(_ request: R, on transport: LineTransport, logger: Logger) {
        do {
            try transport.sendNoReply(cmd: R.command, onError: { error in
                logger.error("\(R.command, privacy: .public) failed: \(error.description, privacy: .public)")
            }) { id in
                try WireCoding.encodeRequest(request, id: id)
            }
        } catch {
            logger.debug("\(R.command, privacy: .public) dropped after close")
        }
    }
}
