import SwiftUI

/// Refreshes the AppKit pane overlay from the small set of inputs that can
/// change its render state.
///
/// This is a SwiftUI observation leaf rather than a `WindowAccessor` refresh
/// closure on `ContentView`. Its revision changes only for overlay inputs, so
/// unrelated parent updates never call the overlay builder.
struct TmuxWorkspacePaneOverlayRefresher: View {
    let builder: TmuxWorkspacePaneOverlayStateBuilder

    @State private var refreshRevision: UInt64 = 0

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .background(
                WindowAccessor(refreshID: refreshRevision) { window in
                    builder.refresh(in: window)
                }
            )
            .onChange(of: builder.tabManager.selectedTabId) { _, _ in
                refreshRevision &+= 1
            }
            .onChange(of: builder.sidebarUnread.snapshot) { _, _ in
                refreshRevision &+= 1
            }
            .onChange(of: builder.experiment.target) { _, _ in
                refreshRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      tabId == builder.tabManager.selectedTabId else { return }
                refreshRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceLayoutModeDidChange)) { notification in
                guard (notification.object as? Workspace)?.id == builder.tabManager.selectedTabId else { return }
                refreshRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspacePaneUnreadStateDidChange)) { notification in
                guard (notification.object as? Workspace)?.id == builder.tabManager.selectedTabId else { return }
                refreshRevision &+= 1
            }
    }
}

extension Notification.Name {
    /// Posted when a workspace's restored pane unread indicators change.
    static let workspacePaneUnreadStateDidChange = Notification.Name(
        "cmux.workspacePaneUnreadStateDidChange"
    )
}
