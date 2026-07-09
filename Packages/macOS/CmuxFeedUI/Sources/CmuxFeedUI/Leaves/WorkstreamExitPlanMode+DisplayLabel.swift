import Foundation
public import CMUXAgentLaunch

public extension WorkstreamExitPlanMode {
    /// Compact localized label for the exit-plan mode, shown in a feed item's
    /// resolved badge (e.g. "Submitted · auto"). Strings resolve from the app's
    /// main bundle (`bundle: .main`) so the app-side `.xcstrings` catalog and its
    /// non-English translations are used, not the package bundle.
    var displayLabel: String {
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
