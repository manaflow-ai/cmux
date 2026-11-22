extension DaemonConnection {
    /// The `after: "sync"` barrier (plans/cmux-next/state-ownership.md 4.3): one `identify` round
    /// trip, then the event sequence routed before its reply; nil when the connection is not ready.
    /// No wall clock (#32724): the daemon answers `identify` before its connection's queue, so only
    /// load delays it, and load must not fail a request. The ask ends with its reply or the
    /// connection's end; the heartbeat ends a local connection only when the daemon process is gone.
    public func syncBarrierSequence() async throws -> UInt64? {
        _ = try await request(IdentifyRequest(), timeout: nil)
        return eventSequence()
    }
}
