import Foundation

/// The deadlines and grace periods ``CloudTunnelCoordinator`` runs on. Tests
/// inject short values with a manual clock; production uses the defaults.
struct CloudTunnelTiming: Sendable {
    /// Quiet time after the last Cloud use before an unpinned tunnel with
    /// no live consumers stops.
    var idleGrace: Duration = .seconds(300)
    /// How long a private-network use waits for the tunnel before the
    /// caller dials anyway.
    var readinessBudget: Duration = .seconds(20)
    /// Budget for the link to connect once the start request is accepted.
    /// Waiting for the user's one-time extension approval is not counted.
    var connectTimeout: Duration = .seconds(45)
    var stopTimeout: Duration = .seconds(10)
    /// After a failed start, Cloud uses do not retry the start (enroll,
    /// activate, save, connect) for this long; `cmux vpn up` always does.
    var failureBackoff: Duration = .seconds(30)
}
