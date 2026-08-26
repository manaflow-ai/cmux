import Foundation

/// One tab (panel) inside a workspace, described by both of its identities.
struct CmuxNavigationSurfaceDescriptor: Equatable {
    /// Session-scoped panel identifier (`Panel.id`).
    let panelId: UUID
    /// Current session-owned surface identifiers that route to this panel.
    let runtimeSurfaceIds: [UUID]
    /// Restart-stable surface identifier (`Panel.stableSurfaceId`).
    let stableSurfaceId: UUID

    init(panelId: UUID, runtimeSurfaceIds: [UUID] = [], stableSurfaceId: UUID) {
        self.panelId = panelId
        self.runtimeSurfaceIds = runtimeSurfaceIds
        self.stableSurfaceId = stableSurfaceId
    }
}
