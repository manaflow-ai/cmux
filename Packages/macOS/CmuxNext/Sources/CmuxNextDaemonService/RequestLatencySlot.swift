import CmuxNextCompat
public import CmuxNextDaemon

/// The local connection's daemon-request probe, once ``DaemonService`` starts it: a reference the
/// `debug.daemon_requests` method captures (a `Mutex` cannot be captured: it is not copyable). Set once
/// at start on the main actor, read from any thread (the control socket's snapshot methods run off
/// main), so it is nonisolated, not main-actor state: Sendable through its `Mutex`, no `@unchecked`.
public nonisolated final class RequestLatencySlot: Sendable {
    private let value = Mutex<DaemonRequestLatency?>(nil)

    public init() {}

    /// The probe; nil before the local connection starts.
    public var probe: DaemonRequestLatency? { value.withLock { $0 } }

    func set(_ probe: DaemonRequestLatency?) { value.withLock { $0 = probe } }
}
