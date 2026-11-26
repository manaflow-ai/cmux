import SwiftUI

/// Observes all overlay inputs in one leaf, separate from ContentView.
/// WindowAccessor only forwards changed value snapshots or window attachments.
struct TmuxWorkspacePaneOverlayRefresher: View, Equatable {
    let builder: TmuxWorkspacePaneOverlayStateBuilder
    let coordinator: TmuxWorkspacePaneOverlayCoordinator
    private let dependencyIdentity: [ObjectIdentifier]
    private let workspaceIdentity: ObjectIdentifier?
    private let settings: TmuxWorkspacePaneOverlaySettings

    init(builder: TmuxWorkspacePaneOverlayStateBuilder, coordinator: TmuxWorkspacePaneOverlayCoordinator) {
        self.builder = builder
        self.coordinator = coordinator
        settings = builder.settings
        workspaceIdentity = builder.tabManager.selectedWorkspace.map { ObjectIdentifier($0) }
        dependencyIdentity = [ObjectIdentifier(builder.tabManager), ObjectIdentifier(builder.sidebarUnread),
                              ObjectIdentifier(builder.experiment), ObjectIdentifier(coordinator)]
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dependencyIdentity == rhs.dependencyIdentity
            && lhs.workspaceIdentity == rhs.workspaceIdentity
            && lhs.settings == rhs.settings
    }

    var body: some View {
        let inputs = builder.inputs
        Color.clear
            .frame(width: 0, height: 0)
            .background(WindowAccessor(refreshID: inputs) { window in
                coordinator.refresh(builder: builder, in: window)
            })
            .onReceive(NotificationCenter.default.publisher(for: .workspacePaneGeometryDidChange)) { notification in
                guard (notification.object as? Workspace)?.id == inputs.workspaceId else { return }
                coordinator.scheduleGeometryRefresh(builder: builder)
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspacePaneFlashDidChange)) { notification in
                guard (notification.object as? Workspace)?.id == inputs.workspaceId else { return }
                coordinator.refresh(builder: builder)
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceLayoutModeDidChange)) { notification in
                guard (notification.object as? Workspace)?.id == inputs.workspaceId else { return }
                coordinator.refresh(builder: builder)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      tabId == inputs.workspaceId else { return }
                coordinator.refresh(builder: builder)
            }
            .onDisappear { coordinator.detach() }
    }
}
