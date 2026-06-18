public import Foundation

/// The outcome of `pane.resize`, preserving every distinct branch of the legacy
/// `v2PaneResize` body — both the absolute and the relative resize paths, with
/// their separate success payloads.
///
/// The coordinator performs the pre-flight `invalid_params` validation (the
/// absolute-axis / target-pixels / direction checks that do not touch app
/// state) and shapes the final `JSONValue`; the seam runs the split-tree
/// candidate collection and divider mutation and returns this resolution.
public enum ControlPaneResizeResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// A TabManager resolved but no workspace did (legacy `not_found` /
    /// "Workspace not found", `data: nil`).
    case workspaceNotFound
    /// No `pane_id` was given and the workspace had no focused pane (legacy
    /// `not_found` / "No focused pane", `data: nil`).
    case noFocusedPane
    /// The pane id did not match any pane (legacy `not_found` / "Pane not
    /// found", `data: {"pane_id": …}`). Carries the unresolved pane id.
    case paneNotFound(UUID)
    /// The pane was not found in the split tree (legacy `not_found` / "Pane not
    /// found in split tree", `data: {"pane_id": …}`). Carries the pane id.
    case paneNotFoundInTree(UUID)
    /// The absolute resize found no split ancestor (legacy `invalid_state` / "No
    /// split ancestor for absolute pane resize", `data: {"pane_id": …,
    /// "absolute_axis": axis-or-null}`). Carries the pane id and axis (axis may
    /// be absent, matching the legacy `v2OrNull`).
    case noAbsoluteSplitAncestor(paneID: UUID, absoluteAxis: String?)
    /// The relative resize found no split ancestor in the requested orientation
    /// (legacy `invalid_state` / "No <orientation> split ancestor for pane",
    /// `data: {"pane_id": …, "direction": …}`). Carries the pane id,
    /// orientation, and direction.
    case noOrientationSplitAncestor(paneID: UUID, orientation: String, direction: String)
    /// The pane has no adjacent border in the requested direction (legacy
    /// `invalid_state` / "Pane has no adjacent border in direction <direction>",
    /// `data: {"pane_id": …, "direction": …}`). Carries the pane id and
    /// direction.
    case noAdjacentBorder(paneID: UUID, direction: String)
    /// Setting the split divider position failed (legacy `internal_error` /
    /// "Failed to set split divider position", `data: {"split_id": …}`). Carries
    /// the split id.
    case setDividerFailed(splitID: UUID)
    /// The absolute resize succeeded. Carries the echoed identity plus the
    /// split, axis, target pixels, and old/new divider positions.
    case absoluteResized(
        windowID: UUID?,
        workspaceID: UUID,
        paneID: UUID,
        splitID: UUID,
        absoluteAxis: String,
        targetPixels: Double,
        oldDividerPosition: Double,
        newDividerPosition: Double
    )
    /// The relative resize succeeded. Carries the echoed identity plus the
    /// split, direction, amount, and old/new divider positions.
    case relativeResized(
        windowID: UUID?,
        workspaceID: UUID,
        paneID: UUID,
        splitID: UUID,
        direction: String,
        amount: Int,
        oldDividerPosition: Double,
        newDividerPosition: Double
    )
}
