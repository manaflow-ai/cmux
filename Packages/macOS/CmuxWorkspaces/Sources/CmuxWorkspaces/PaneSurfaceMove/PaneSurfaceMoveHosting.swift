public import Foundation
public import Bonsplit

/// The live-workspace operations ``PaneSurfaceMoveCoordinator`` reaches back into
/// when it moves a surface between panes/workspaces/windows.
///
/// ``PaneSurfaceMoveCoordinator`` owns the *decision* the legacy `AppDelegate`
/// kept inline (`moveSurface`, `moveBonsplitTab`, and the move-target loop of
/// `workspaceMoveTargets`): which pane resolves the destination, the
/// same-workspace-split vs same-workspace-move vs cross-workspace path, the
/// move-target exclusion filter and projection, and the bonsplit-tab → panel-id
/// indirection. None of that holds an app object; it routes value types.
///
/// Everything the decision drives is irreducibly app-coupled and stays on the
/// app target behind this seam: the live `Workspace`/`TabManager`/bonsplit
/// mutations (detach/attach/split/move/cleanup/focus), the `NSWindow` focus and
/// the two-shot cross-window focus reassert, and the cross-workspace detach-scoped
/// tail whose detached-surface transfer token is an app type that cannot cross
/// the package boundary. The app target conforms and is injected via
/// ``PaneSurfaceMoveCoordinator/attach(host:)``; every method mirrors one read,
/// mutation, or scheduled effect the legacy bodies performed, in their legacy
/// order, so the move is byte-faithful (the app-bundle `cmuxDebugLog` tracing
/// whose ordering relative to the live steps is observable also stays in the host
/// step implementations).
///
/// Pane ids are Bonsplit's `PaneID` (the same value type the app target uses
/// directly), so the seam speaks it without an associated type. `@MainActor`
/// because every surface-move effect is one main-actor turn driven by a menu /
/// drop / socket action, so the host lives where its callers live (mirrors the
/// sibling ``WorkspaceDropHosting``/``WorkspaceContextMenuHosting`` rulings).
@MainActor
public protocol PaneSurfaceMoveHosting: AnyObject {
    // MARK: - Surface location

    /// Resolves the window + workspace that currently own `surfaceId`, or `nil`
    /// when no live or recoverable workspace holds it. Mirrors the legacy
    /// `AppDelegate.locateSurface(surfaceId:)` (live windows first, then
    /// recoverable routes), dropping the live `TabManager` the coordinator does
    /// not need.
    func resolveSourceLocation(surfaceId: UUID) -> PaneSurfaceMoveSourceLocation?

    /// Resolves the window + workspace + panel id for an existing bonsplit tab id,
    /// or `nil` when no live or recoverable workspace holds it. Mirrors the legacy
    /// `AppDelegate.locateBonsplitSurface(tabId:)`, dropping the live `TabManager`.
    func resolveBonsplitLocation(tabId: UUID) -> (location: PaneSurfaceMoveSourceLocation, panelId: UUID)?

    /// Whether the workspace `workspaceId` exists in some live window's manager.
    /// Mirrors the legacy destination existence check (`tabManagerFor(tabId:)` +
    /// `tabs.first(where:)`). Returns `false` when no manager owns it.
    func workspaceExists(_ workspaceId: UUID) -> Bool

    /// The window id that owns the manager holding `workspaceId`, or `nil`.
    /// Mirrors the legacy `windowId(for: destinationManager)` used to focus the
    /// destination window.
    func windowId(forWorkspace workspaceId: UUID) -> UUID?

    // MARK: - Destination pane resolution

    /// Resolves the destination pane for a move into `workspaceId`: the requested
    /// `targetPane` when it exists in the workspace, otherwise the workspace's
    /// focused pane, otherwise its first pane, otherwise `nil`. Mirrors the legacy
    /// `targetPane.flatMap { … allPaneIds.first(where:) } ?? focusedPaneId ??
    /// allPaneIds.first`.
    func resolveTargetPane(inWorkspace workspaceId: UUID, requested targetPane: PaneID?) -> PaneID?

    // MARK: - Same-workspace move

    /// Splits `targetPane` in `workspaceId`, moving the surface `panelId` into the
    /// new side, then focuses the moved surface when `focus` is true; returns
    /// whether the split succeeded. Mirrors the legacy same-workspace
    /// `splitPane(_:orientation:movingTab:insertFirst:) != nil` guard (including
    /// its `surfaceIdFromPanelId(panelId)` resolution) and the subsequent
    /// `focusTab(_:surfaceId:suppressFlash:)`.
    func splitSameWorkspace(
        workspaceId: UUID,
        panelId: UUID,
        targetPane: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool
    ) -> Bool

    /// Moves `panelId` to `targetPane` at `index` within `workspaceId`, returning
    /// whether the move succeeded. Mirrors the legacy same-workspace
    /// `sourceWorkspace.moveSurface(panelId:toPane:atIndex:focus:)`.
    func moveSameWorkspace(
        workspaceId: UUID,
        panelId: UUID,
        targetPane: PaneID,
        atIndex index: Int?,
        focus: Bool
    ) -> Bool

    // MARK: - Cross-workspace move (detach-scoped, app-owned)

    /// Runs the legacy cross-workspace tail of `moveSurface` for `panelId`:
    /// detach from `sourceWorkspaceId` (returning `false` on detach failure),
    /// attach into the plan's destination pane/index (rolling back to the source
    /// pane/index on failure), optionally split (rolling back on failure), clean
    /// up the emptied source workspace, and focus the moved surface + arm the
    /// cross-window reassert per the plan. Returns whether the move succeeded. The
    /// detached transfer token is an app type, so the whole tail stays in the
    /// host; the coordinator supplies only the value-typed ``plan``.
    func performCrossWorkspaceMove(
        panelId: UUID,
        sourceWorkspaceId: UUID,
        sourceWindowId: UUID,
        plan: PaneSurfaceMoveCrossWorkspacePlan
    ) -> Bool
}
