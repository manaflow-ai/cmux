/// Errors raised while selecting or canonicalizing routes for a pairing target.
public enum CmxMobileAttachRoutePlanningError: Error, Equatable, Sendable {
    /// The caller supplied no routes at all.
    case noRoutes
    /// The supplied routes cannot satisfy the requested target.
    case routeUnavailable
    /// A route could not be reconstructed with the target's canonical identity.
    case invalidRoute
}
