import CmuxSettings
import Foundation

/// App-side display strings for the sidebar active-workspace indicator
/// style (the value type lives in CmuxSettings; localized strings resolve
/// against the app bundle, so they stay app-side).
extension WorkspaceIndicatorStyle {
    var displayName: String {
        switch self {
        case .leftRail:
            return String(localized: "sidebar.activeTabIndicator.leftRail", defaultValue: "Left Rail")
        case .solidFill:
            return String(localized: "sidebar.activeTabIndicator.solidFill", defaultValue: "Solid Fill")
        }
    }
}
