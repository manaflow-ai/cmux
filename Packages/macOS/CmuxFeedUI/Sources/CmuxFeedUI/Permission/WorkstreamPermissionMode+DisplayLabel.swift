public import CMUXAgentLaunch

extension WorkstreamPermissionMode {
    /// Localized one-word label shown after a resolved permission-request item.
    ///
    /// The `feed.permission.mode.*` keys live in the app's
    /// `Resources/Localizable.xcstrings`, so the lookup resolves against the
    /// app's main bundle (`bundle: .main`). Resolving against the package bundle
    /// would silently return the English default and drop every non-English
    /// (Japanese) translation.
    public var displayLabel: String {
        switch self {
        case .once:
            return String(localized: "feed.permission.mode.once", defaultValue: "once", bundle: .main)
        case .always:
            return String(localized: "feed.permission.mode.always", defaultValue: "always", bundle: .main)
        case .all:
            return String(localized: "feed.permission.mode.all", defaultValue: "all tools", bundle: .main)
        case .bypass:
            return String(localized: "feed.permission.mode.bypass", defaultValue: "bypass", bundle: .main)
        case .deny:
            return String(localized: "feed.permission.mode.deny", defaultValue: "denied", bundle: .main)
        }
    }
}
