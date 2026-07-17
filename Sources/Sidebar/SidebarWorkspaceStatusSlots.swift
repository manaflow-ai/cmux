import SwiftUI

enum SidebarWorkspaceLoadingTooltip {
    static func text(count: Int) -> String {
        if count == 1 {
            return String(localized: "sidebar.agentActivity.tooltip.one", defaultValue: "Loading (1 active task)")
        }
        return String(
            localized: "sidebar.agentActivity.tooltip.other",
            defaultValue: "Loading (\(count) active tasks)"
        )
    }
}
