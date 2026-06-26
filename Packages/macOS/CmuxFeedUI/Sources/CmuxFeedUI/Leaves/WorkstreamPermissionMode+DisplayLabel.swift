import Foundation
public import CMUXAgentLaunch

public extension WorkstreamPermissionMode {
    /// Compact localized label for the permission mode, shown in a feed item's
    /// resolved badge (e.g. "Submitted · once"). Strings resolve from the app's
    /// main bundle (`bundle: .main`) so the app-side `.xcstrings` catalog and its
    /// non-English translations are used, not the package bundle.
    var displayLabel: String {
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
