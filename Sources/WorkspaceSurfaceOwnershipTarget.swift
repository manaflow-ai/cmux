import Foundation

/// Resolves a live surface to the stable workspace panel that owns its layout.
///
/// Ordinary surfaces use the same identity for both fields. A projected remote
/// tmux pane keeps its live terminal identity in ``surfaceID`` while mutations
/// that belong to the workspace layout use ``containerPanelID``.
@MainActor
struct WorkspaceSurfaceOwnershipTarget {
    let surfaceID: UUID
    let containerPanelID: UUID
    let panel: any Panel
}
