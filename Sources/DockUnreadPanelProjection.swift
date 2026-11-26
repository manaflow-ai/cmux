import CmuxNotifications
import Foundation
import Observation

/// Narrows unread and agent-attention state to one Dock's Bonsplit subtree.
/// Hidden Docks clear once, then ignore unrelated notification churn.
@MainActor
@Observable
final class DockUnreadPanelProjection {
    /// Panels whose terminal chrome should render the attention ring.
    private(set) var unreadPanelIDs: Set<UUID> = []

    @ObservationIgnored private let workspaceID: UUID
    @ObservationIgnored private var panelIDs: Set<UUID> = []
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var surfaceProjection: SidebarSurfaceUnreadProjection
    @ObservationIgnored private let agentAttentionSource: SurfaceAttentionModel
    @ObservationIgnored private var agentAttentionSurfaceIDs: Set<UUID>
    @ObservationIgnored private var unreadObservation: SidebarUnreadObservation?
    @ObservationIgnored private var agentAttentionObservation: SurfaceAttentionObservation?

    init(
        source: SidebarUnreadModel,
        workspaceID: UUID,
        panelIDs: Set<UUID>,
        isActive: Bool,
        agentAttentionSource: SurfaceAttentionModel
    ) {
        self.workspaceID = workspaceID
        self.panelIDs = panelIDs
        self.isActive = isActive
        surfaceProjection = source.surfaceProjection(forOwnerId: workspaceID)
        self.agentAttentionSource = agentAttentionSource
        agentAttentionSurfaceIDs = agentAttentionSource.surfaceIds
        refresh()
        unreadObservation = source.observeSurfaceChanges(
            forOwnerId: workspaceID,
            owner: self
        ) { projection, surfaceProjection in
            projection.receive(surfaceProjection)
        }
        agentAttentionObservation = self.agentAttentionSource.observeChanges(
            owner: self
        ) { projection, surfaceIDs in
            projection.receiveAgentAttention(surfaceIDs)
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

    private func receiveAgentAttention(_ surfaceIDs: Set<UUID>) {
        agentAttentionSurfaceIDs = surfaceIDs
        refresh()
    }

    private func refresh() {
        let nextUnreadPanelIDs: Set<UUID>
        if isActive {
            nextUnreadPanelIDs = Set(panelIDs.filter { panelID in
                surfaceProjection.hasVisibleIndicator(surfaceId: panelID)
                    || agentAttentionSurfaceIDs.contains(panelID)
            })
        } else {
            nextUnreadPanelIDs = []
        }
        guard unreadPanelIDs != nextUnreadPanelIDs else { return }
        unreadPanelIDs = nextUnreadPanelIDs
    }
}
