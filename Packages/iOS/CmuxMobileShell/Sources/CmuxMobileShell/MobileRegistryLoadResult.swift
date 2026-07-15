/// Result of refreshing the current team's registered devices and routes.
///
/// Device and route records are team-scoped. Live-session arrays in the same
/// response are filtered by the service to the authenticated account.
public enum MobileRegistryLoadResult: Equatable, Sendable {
    /// The authoritative team registry response was applied.
    case loaded
    /// The service rejected the current account or team authorization.
    case authRejected
    /// No authoritative response was available, so existing data may remain visible.
    case unavailable
}
