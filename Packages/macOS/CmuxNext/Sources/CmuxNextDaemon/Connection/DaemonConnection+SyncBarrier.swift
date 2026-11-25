extension DaemonConnection {
    /// The `after: "sync"` barrier (plans/cmux-next/state-ownership.md 4.3): one `identify` round
    /// trip, then the event sequence routed before its reply; nil when the connection is not ready
    /// or its daemon stopped answering.
    /// No wall clock (#32724): the daemon answers `identify` before its connection's queue, so only
    /// load delays it, and load must not fail a request. The ask ends with its reply, the
    /// connection's end, or the heartbeat's not-answering verdict (``ConnectionHeartbeat/untilSilent(_:)``):
    /// silence, not slowness. Before it, a wedged or stopped daemon (SIGSTOP) whose process stays
    /// alive kept the connection open, and a `cmux ... --after sync` waited on it forever
    /// (no-hangs, 2026-11-24); now it ends as `unavailable` after the heartbeat's 30 s of silence.
    /// The `identify` itself goes on: it has no side effect, and its late reply is dropped.
    public func syncBarrierSequence() async throws -> UInt64? {
        let answered: Void? = try await heartbeat.untilSilent { [self] in
            _ = try await request(IdentifyRequest(), timeout: nil)
        }
        guard answered != nil else { return nil }
        return eventSequence()
    }
}
