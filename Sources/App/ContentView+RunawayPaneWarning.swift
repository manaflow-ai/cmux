import SwiftUI

extension ContentView {
    @ViewBuilder
    func runawayPaneWarningBackground(
        tabManager: TabManager,
        selection: SidebarSelectionState
    ) -> some View {
        if let center = AppDelegate.shared?.runawayPaneWarningCenter {
            RunawayPaneWarningOverlayHost(
                center: center,
                workspaceIDs: Set(tabManager.tabs.map(\.id)),
                windowId: windowId,
                isShowingWorkspaces: selection.selection == .tabs
            )
        }
    }
}
