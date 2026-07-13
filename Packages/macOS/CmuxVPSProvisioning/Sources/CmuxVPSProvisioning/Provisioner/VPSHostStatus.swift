/// Composite status of one registered host, as shown by `cmux vps status`.
public struct VPSHostStatus: Equatable, Sendable {
    /// Probe result, or `nil` when SSH failed.
    public var facts: VPSHostFacts?
    /// Daemon socket probe results, or `nil` when unavailable (no binary,
    /// binary predates `daemon-status`, or the host was unreachable).
    public var report: VPSRemoteDaemonStatusReport?
    /// Health classification from the real daemon signals above.
    public var health: VPSHostHealth
    /// Version this client would install (drift comparison baseline).
    public var desiredVersion: String

    /// Creates a status value.
    public init(
        facts: VPSHostFacts?,
        report: VPSRemoteDaemonStatusReport?,
        health: VPSHostHealth,
        desiredVersion: String
    ) {
        self.facts = facts
        self.report = report
        self.health = health
        self.desiredVersion = desiredVersion
    }
}
