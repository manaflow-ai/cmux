public import Foundation

/// The outcome of `pane.swap`, preserving every distinct branch of the legacy
/// `v2PaneSwap` body and the swapped identity it echoes back.
///
/// The coordinator validates `pane_id`/`target_pane_id` (returning
/// `invalid_params` itself); the seam locates the panes, performs the swap
/// (with stable-identity placeholders), and returns this resolution.
public enum ControlPaneSwapResolution: Sendable, Equatable {
    /// The source pane was not found (legacy `not_found` / "Source pane not
    /// found", `data: {"pane_id": …}`). Carries the source pane id.
    case sourcePaneNotFound(UUID)
    /// The target pane was not found in the source workspace (legacy `not_found`
    /// / "Target pane not found in source workspace", `data: {"target_pane_id":
    /// …}`). Carries the target pane id.
    case targetPaneNotFound(UUID)
    /// One or both panes had no selected surface (legacy `invalid_state` / "Both
    /// panes must have a selected surface", `data: nil`).
    case bothPanesNeedSurface
    /// Creating the source-pane stability placeholder failed (legacy
    /// `internal_error` / "Failed to create source placeholder surface", `data:
    /// nil`).
    case sourcePlaceholderFailed
    /// Creating the target-pane stability placeholder failed (legacy
    /// `internal_error` / "Failed to create target placeholder surface", `data:
    /// nil`).
    case targetPlaceholderFailed
    /// Moving the source surface into the target pane failed (legacy
    /// `internal_error` / "Failed moving source surface into target pane",
    /// `data: nil`).
    case moveSourceFailed
    /// Moving the target surface into the source pane failed (legacy
    /// `internal_error` / "Failed moving target surface into source pane",
    /// `data: nil`).
    case moveTargetFailed
    /// The swap succeeded. Carries the echoed window/workspace/pane/surface
    /// identity for both sides.
    case swapped(
        windowID: UUID,
        workspaceID: UUID,
        sourcePaneID: UUID,
        targetPaneID: UUID,
        sourceSurfaceID: UUID,
        targetSurfaceID: UUID
    )
}
