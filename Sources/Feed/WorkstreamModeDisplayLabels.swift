import CMUXAgentLaunch
import Foundation

// App-side localized display labels for the Workstream decision-mode enums.
//
// These deliberately live in the app target, not in `CMUXAgentLaunch`, because
// `String(localized:)` resolves against the *calling module's* bundle. The
// `feed.permission.mode.*` / `feed.exitplan.mode.*` keys live only in the app's
// `Resources/Localizable.xcstrings`; calling `String(localized:)` from inside
// the package would bind to the package bundle, silently return the English
// default, and drop every non-English (Japanese) translation. So the
// presentation labels stay app-side while the enums themselves stay in
// `CMUXAgentLaunch/Workstream`.

extension WorkstreamPermissionMode {
    /// Localized one-word label shown after a resolved permission-request item.
    var displayLabel: String {
        switch self {
        case .once:
            return String(localized: "feed.permission.mode.once", defaultValue: "once")
        case .always:
            return String(localized: "feed.permission.mode.always", defaultValue: "always")
        case .all:
            return String(localized: "feed.permission.mode.all", defaultValue: "all tools")
        case .bypass:
            return String(localized: "feed.permission.mode.bypass", defaultValue: "bypass")
        case .deny:
            return String(localized: "feed.permission.mode.deny", defaultValue: "denied")
        }
    }
}

extension WorkstreamExitPlanMode {
    /// Localized one-word label shown after a resolved exit-plan item.
    var displayLabel: String {
        switch self {
        case .ultraplan:
            return String(localized: "feed.exitplan.mode.ultraplan", defaultValue: "ultraplan")
        case .bypassPermissions:
            return String(localized: "feed.exitplan.mode.bypass", defaultValue: "bypass")
        case .autoAccept:
            return String(localized: "feed.exitplan.mode.autoAccept", defaultValue: "auto")
        case .manual:
            return String(localized: "feed.exitplan.mode.manual", defaultValue: "manual")
        case .deny:
            return String(localized: "feed.exitplan.mode.deny", defaultValue: "denied")
        }
    }
}
