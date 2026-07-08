import Foundation

/// One tab (panel) inside a workspace, described by both of its identities.
struct CmuxNavigationSurfaceDescriptor: Equatable {
    /// Session-scoped panel identifier (`Panel.id`).
    let panelId: UUID
    /// Restart-stable surface identifier (`Panel.stableSurfaceId`).
    let stableSurfaceId: UUID
}
