public import CMUXAgentLaunch

extension WorkstreamExitPlanMode {
    /// Localized one-word label shown after a resolved exit-plan item.
    ///
    /// The `feed.exitplan.mode.*` keys live in the app's
    /// `Resources/Localizable.xcstrings`, so the lookup resolves against the
    /// app's main bundle (`bundle: .main`). Resolving against the package bundle
    /// would silently return the English default and drop every non-English
    /// (Japanese) translation.
    public var displayLabel: String {
        switch self {
        case .ultraplan:
            return String(localized: "feed.exitplan.mode.ultraplan", defaultValue: "ultraplan", bundle: .main)
        case .bypassPermissions:
            return String(localized: "feed.exitplan.mode.bypass", defaultValue: "bypass", bundle: .main)
        case .autoAccept:
            return String(localized: "feed.exitplan.mode.autoAccept", defaultValue: "auto", bundle: .main)
        case .manual:
            return String(localized: "feed.exitplan.mode.manual", defaultValue: "manual", bundle: .main)
        case .deny:
            return String(localized: "feed.exitplan.mode.deny", defaultValue: "denied", bundle: .main)
        }
    }
}
