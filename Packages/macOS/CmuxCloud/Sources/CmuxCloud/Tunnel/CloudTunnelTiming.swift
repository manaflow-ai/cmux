import Foundation

/// The deadlines and grace periods ``CloudTunnelCoordinator`` runs on. Tests
/// inject short values with a manual clock; production uses the defaults.
public struct CloudTunnelTiming: Sendable {
    public init(
        idleGrace: Duration = .seconds(300),
        readinessBudget: Duration = .seconds(20),
        connectTimeout: Duration = .seconds(45),
        stopTimeout: Duration = .seconds(10),
        failureBackoff: Duration = .seconds(30)
    ) {
        self.idleGrace = idleGrace
        self.readinessBudget = readinessBudget
        self.connectTimeout = connectTimeout
        self.stopTimeout = stopTimeout
        self.failureBackoff = failureBackoff
    }

    /// Quiet time after the last Cloud use before an unpinned tunnel with
    /// no live consumers stops.
    public var idleGrace: Duration = .seconds(300)
    /// How long a private-network use waits for the tunnel before the
    /// caller dials anyway.
    public var readinessBudget: Duration = .seconds(20)
    /// Budget for the link to connect once the start request is accepted.
    /// Waiting for the user's one-time extension approval is not counted.
    public var connectTimeout: Duration = .seconds(45)
    public var stopTimeout: Duration = .seconds(10)
    /// After a failed start, Cloud uses do not retry the start (enroll,
    /// activate, save, connect) for this long; `cmux vpn up` always does.
    public var failureBackoff: Duration = .seconds(30)
}
