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

public extension NotificationFeedPermissionCapabilities {
    /// The notification category identifier whose registered actions match this
    /// capability set. The supported modes are concatenated in `Once`/`Always`/`All`
    /// order onto the `CMUXFeedPermission` prefix; a set with no supported modes
    /// falls back to the deny-only `CMUXFeedPermissionDeny` category.
    var notificationCategoryIdentifier: String {
        var suffix = ""
        if supportsOnce { suffix += "Once" }
        if supportsAlways { suffix += "Always" }
        if supportsAll { suffix += "All" }
        return suffix.isEmpty ? "CMUXFeedPermissionDeny" : "CMUXFeedPermission\(suffix)"
    }
}
