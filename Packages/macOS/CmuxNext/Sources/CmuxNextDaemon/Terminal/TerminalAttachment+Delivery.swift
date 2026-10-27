import os

extension TerminalAttachment {
    /// How a view's events reach it when its consumer falls 8 MiB behind (p05-ipc-099).
    enum Delivery: Sendable {
        /// Its own attach connection (the legacy path): the reader thread parks, the daemon's attach
        /// mailbox overflows and ends the stream with `overflow`, and the view reattaches.
        case ownConnection
        /// A stream on the machine's shared connection (`attach-streams-v1`, p05-ipc-095): the reader
        /// never waits, so a stopped view delays no other stream and no control reply. The view drops
        /// its output and asks for one fresh READY (`snapshot-request`) instead.
        case sharedStream
    }

    /// The queue's policy for `delivery`. A shared stream's resync asks the host for one READY + history
    /// on this attach; the request is fire-and-forget, so the reader thread that overflows never waits.
    /// Dropped output is a `gap`, the wire's reason for missing output.
    nonisolated static func backpressure(
        for delivery: Delivery, transport: LineTransport, surface: @escaping @Sendable () -> SurfaceID
    ) -> TerminalEventQueue.Backpressure {
        switch delivery {
        case .ownConnection:
            return .parkReader
        case .sharedStream:
            let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.attach")
            return .dropAndResync(onResync: {
                Self.fireAndForget(SnapshotRequestRequest(surface: surface(), reason: .gap), on: transport, logger: logger)
            })
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
