import SwiftUI

enum SidebarWorkspaceLoadingTooltip {
    static func text(count: Int) -> String {
        if count == 1 {
            return String(localized: "sidebar.agentActivity.tooltip.one", defaultValue: "Loading (1 active task)")
        }
        return String.localizedStringWithFormat(
            String(localized: "sidebar.agentActivity.tooltip.many", defaultValue: "Loading (%lld active tasks)"),
            Int64(count)
        )
    }
}
