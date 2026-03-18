import SwiftUI
import Bonsplit

/// A minimal SwiftUI view that renders a single workspace's bonsplit content
/// for the Quick Terminal window. No sidebar, no tab bar — just the terminal panes.
struct QuickTerminalContentView: View {
    /// The tab manager that owns the Quick Terminal's workspace and panes.
    @ObservedObject var tabManager: TabManager
    /// Shared notification store for terminal notifications.
    @ObservedObject var notificationStore: TerminalNotificationStore

    /// Render the selected workspace's terminal panes.
    var body: some View {
        if let workspace = tabManager.selectedWorkspace {
            WorkspaceContentView(
                workspace: workspace,
                isWorkspaceVisible: true,
                isWorkspaceInputActive: true,
                workspacePortalPriority: 2,
                onThemeRefreshRequest: nil
            )
            .environmentObject(notificationStore)
        }
    }
}
