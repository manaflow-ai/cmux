import Foundation

/// The two answers ``CloudTunnelCoordinator`` needs from
/// ``CloudActivationPolicy`` before it starts the tunnel.
///
/// `knownRefusal` reads local state only and is what status reporting and
/// the runtime opt-out observer use; an unknown machine count is not a
/// refusal there. `resolvedRefusal` is what every start path awaits: it may
/// ask the control plane once when the local machine count is unknown (the
/// cache is cleared on sign-out and empty on a fresh opt-in), so an explicit
/// Cloud use right after sign-in is admitted on the account's real fleet
/// instead of on a stale marker. Neither touches NetworkExtension.
public struct CloudTunnelAdmission: Sendable {
    public init(
        knownRefusal: @escaping @Sendable () -> CloudTunnelStartRefusal?,
        resolvedRefusal: @escaping @Sendable () async -> CloudTunnelStartRefusal?
    ) {
        self.knownRefusal = knownRefusal
        self.resolvedRefusal = resolvedRefusal
    }

    public let knownRefusal: @Sendable () -> CloudTunnelStartRefusal?
    public let resolvedRefusal: @Sendable () async -> CloudTunnelStartRefusal?

    /// Admits everything; for coordinators whose policy lives elsewhere (tests).
    public static let open = CloudTunnelAdmission(knownRefusal: { nil }, resolvedRefusal: { nil })

    /// One answer for both questions, when nothing needs resolving.
    public static func constant(_ refusal: @escaping @Sendable () -> CloudTunnelStartRefusal?) -> CloudTunnelAdmission {
        CloudTunnelAdmission(knownRefusal: refusal, resolvedRefusal: { refusal() })
    }
}
