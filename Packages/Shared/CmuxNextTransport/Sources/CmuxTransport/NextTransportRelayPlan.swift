import Foundation

/// How start() attaches the relay leg — decided once, from what is on hand
/// at bind time. Binding itself NEVER waits on the broker.
public enum NextTransportRelayPlan: Equatable, Sendable {
    /// No broker client and nothing cached: the host is deliberately
    /// direct-only and skips the relay leg entirely.
    case directOnlyDeliberate
    /// Still-valid cached credentials go straight into the initial relay
    /// map; a background mint refreshes them make-before-break.
    case cachedCredential
    /// A broker client exists but nothing usable is cached: bind now with
    /// an empty relay map and attach the relay when the first background
    /// mint lands. Publication waits for that first attach.
    case awaitFirstMint

    /// Chooses a startup plan without waiting for broker availability.
    ///
    /// - Parameters:
    ///   - hasBrokerClient: Whether this host can request new credentials.
    ///   - hasUsableCache: Whether protected persistence supplied usable credentials.
    /// - Returns: The cache-first relay attachment plan.
    public static func make(hasBrokerClient: Bool, hasUsableCache: Bool) -> NextTransportRelayPlan {
        if hasUsableCache { return .cachedCredential }
        return hasBrokerClient ? .awaitFirstMint : .directOnlyDeliberate
    }
}
