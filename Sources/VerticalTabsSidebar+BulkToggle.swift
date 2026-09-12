import SwiftUI

extension VerticalTabsSidebar {
    func workspaceGroupBulkToggleTitlebarOverlay(renderContext: WorkspaceListRenderContext) -> some View {
        ZStack(alignment: .topTrailing) {
            // The sidebar top strip remains draggable and handles double-clicks
            // with the standard titlebar action.
            WindowDragHandleView()
                .frame(height: MinimalModeChromeMetrics.titlebarHeight)
                .background(TitlebarDoubleClickMonitorView())
            workspaceGroupBulkToggleOverlay(renderContext: renderContext)
                .padding(.top, 4)
                .padding(.trailing, 6)
        }
        .frame(height: MinimalModeChromeMetrics.titlebarHeight)
    }

    @ViewBuilder
    func workspaceGroupBulkToggleOverlay(renderContext: WorkspaceListRenderContext) -> some View {
        if isPresented, !renderContext.workspaceGroups.isEmpty {
            SidebarWorkspaceGroupBulkToggle(
                allGroupsCollapsed: renderContext.workspaceGroups.allSatisfy(\.isCollapsed),
                onCollapseAll: { [weak tabManager] in tabManager?.collapseAllWorkspaceGroups() },
                onExpandAll: { [weak tabManager] in tabManager?.expandAllWorkspaceGroups() }
            )
        }
    }
}
