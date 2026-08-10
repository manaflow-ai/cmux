import CmuxNotifications
import Foundation
import Observation

/// Narrows the app-wide unread model to this Dock before updating its Bonsplit
/// subtree. Hidden Docks clear once, then ignore unrelated notification churn.
@MainActor
@Observable
final class DockUnreadPanelProjection {
    private(set) var unreadPanelIDs: Set<UUID> = []

    @ObservationIgnored private let workspaceID: UUID
    @ObservationIgnored private var panelIDs: Set<UUID> = []
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>
    @ObservationIgnored private var focusedReadIndicatorByWorkspaceID: [UUID: UUID]
    @ObservationIgnored private var unreadObservation: SidebarUnreadObservation?

    init(
        source: SidebarUnreadModel,
        workspaceID: UUID,
        panelIDs: Set<UUID>,
        isActive: Bool
    ) {
        self.workspaceID = workspaceID
        self.panelIDs = panelIDs
        self.isActive = isActive
        let initialSnapshot = source.snapshot
        unreadSurfaceKeys = initialSnapshot.unreadSurfaceKeys
        focusedReadIndicatorByWorkspaceID = initialSnapshot.focusedReadIndicatorByWorkspaceId
        refresh()
        unreadObservation = source.observeChanges(owner: self) { projection, snapshot in
            projection.receive(
                unreadSurfaceKeys: snapshot.unreadSurfaceKeys,
                focusedReadIndicatorByWorkspaceID: snapshot.focusedReadIndicatorByWorkspaceId
            )
        }
    }

    func updateContext(panelIDs: Set<UUID>, isActive: Bool) {
        guard self.panelIDs != panelIDs || self.isActive != isActive else { return }
        self.panelIDs = panelIDs
        self.isActive = isActive
        refresh()
    }

    private func receive(
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        focusedReadIndicatorByWorkspaceID: [UUID: UUID]
    ) {
        self.unreadSurfaceKeys = unreadSurfaceKeys
        self.focusedReadIndicatorByWorkspaceID = focusedReadIndicatorByWorkspaceID
        refresh()
    }

    private func refresh() {
        let nextUnreadPanelIDs: Set<UUID>
        if isActive {
            let focusedReadPanelID = focusedReadIndicatorByWorkspaceID[workspaceID]
            nextUnreadPanelIDs = Set(panelIDs.filter { panelID in
                unreadSurfaceKeys.contains(
                    SidebarSurfaceUnreadKey(workspaceId: workspaceID, surfaceId: panelID)
                ) || focusedReadPanelID == panelID
            })
        } else {
            nextUnreadPanelIDs = []
        }
        guard unreadPanelIDs != nextUnreadPanelIDs else { return }
        unreadPanelIDs = nextUnreadPanelIDs
    }
}
