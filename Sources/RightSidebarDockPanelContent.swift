import SwiftUI

/// Bridges the app-owned Dock store into a right-sidebar panel descriptor.
struct RightSidebarDockPanelContent: View {
    let context: RightSidebarPanelContext

    var body: some View {
        if let app = AppDelegate.shared,
           let dock = app.windowDock(for: context.tabManager) {
            DockPanelView(
                store: dock,
                isSidebarVisible: context.fileExplorerState.isVisible,
                mode: context.fileExplorerState.mode,
                rootDirectory: nil,
                windowAppearance: context.windowAppearance,
                rightSidebarOwnsInputFocus: context.fileExplorerState.rightSidebarOwnsInputFocus,
                unreadSource: TerminalNotificationStore.shared.sidebarUnread
            )
            .id("dock.window.\(dock.workspaceId.uuidString)")
        } else {
            Color.clear
        }
    }
}
