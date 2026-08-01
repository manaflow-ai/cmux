import Foundation
import SwiftUI

/// Switches the top-chrome action between collapsing and expanding every workspace group.
struct SidebarWorkspaceGroupBulkToggle: View {
    let allGroupsCollapsed: Bool
    let onCollapseAll: @MainActor () -> Void
    let onExpandAll: @MainActor () -> Void

    private var title: String {
        allGroupsCollapsed
            ? String(
                localized: "workspaceGroup.expandAll",
                defaultValue: "Expand All Workspace Groups"
            )
            : String(
                localized: "workspaceGroup.collapseAll",
                defaultValue: "Collapse All Workspace Groups"
            )
    }

    private var systemName: String {
        allGroupsCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
    }

    var body: some View {
        Button(action: allGroupsCollapsed ? onExpandAll : onCollapseAll) {
            CmuxSystemSymbolImage(
                systemName: systemName,
                pointSize: HeaderChromeControlMetrics.iconSize,
                weight: .regular
            )
            .foregroundStyle(.secondary)
            .frame(
                width: HeaderChromeControlMetrics.buttonSize,
                height: HeaderChromeControlMetrics.buttonSize
            )
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .accessibilityElement(children: .ignore)
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("SidebarWorkspaceGroupBulkToggle")
    }
}
