/// Permission actions supported by the pending feed request that owns a
/// notification response.
public struct NotificationFeedPermissionCapabilities: Sendable, Equatable {
    /// Whether the request supports the "once" permission mode.
    public let supportsOnce: Bool

    /// Whether the request supports the "always" permission mode.
    public let supportsAlways: Bool

    /// Whether the request supports the "all" permission mode.
    public let supportsAll: Bool

    /// Creates a capabilities snapshot for a feed permission request.
    public init(supportsOnce: Bool, supportsAlways: Bool, supportsAll: Bool) {
        self.supportsOnce = supportsOnce
        self.supportsAlways = supportsAlways
        self.supportsAll = supportsAll
    }
}
