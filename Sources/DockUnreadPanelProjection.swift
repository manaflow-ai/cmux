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
    @ObservationIgnored private var surfaceProjection: SidebarSurfaceUnreadProjection
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
        surfaceProjection = source.surfaceProjection(forOwnerId: workspaceID)
        refresh()
        unreadObservation = source.observeSurfaceChanges(
            forOwnerId: workspaceID,
            owner: self
        ) { projection, surfaceProjection in
            projection.receive(surfaceProjection)
        }
    }

    func updateContext(panelIDs: Set<UUID>, isActive: Bool) {
        guard self.panelIDs != panelIDs || self.isActive != isActive else { return }
        self.panelIDs = panelIDs
        self.isActive = isActive
        refresh()
    }

    private func receive(_ surfaceProjection: SidebarSurfaceUnreadProjection) {
        self.surfaceProjection = surfaceProjection
        refresh()
    }

    private func refresh() {
        let nextUnreadPanelIDs: Set<UUID>
        if isActive {
            nextUnreadPanelIDs = Set(panelIDs.filter { panelID in
                surfaceProjection.hasVisibleIndicator(surfaceId: panelID)
            })
        } else {
            nextUnreadPanelIDs = []
        }
        guard unreadPanelIDs != nextUnreadPanelIDs else { return }
        unreadPanelIDs = nextUnreadPanelIDs
    }
}
