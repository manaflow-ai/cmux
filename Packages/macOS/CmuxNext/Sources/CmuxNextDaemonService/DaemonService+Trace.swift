public import CmuxNextControl

extension DaemonService {
    /// This machine's daemon trace commands (`trace-start`, `trace-stop` and `trace-status`, p09-observability
    /// task 015) for the control socket's `trace.start` (task 020). Each call reads the connection current
    /// then, so a reconnect between a start and its stop still reaches the daemon.
    public var traceLink: DaemonTraceLink {
        DaemonTraceLink { [weak self] in await self?.connection }
    }
}
