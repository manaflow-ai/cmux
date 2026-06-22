public import Foundation
public import Bonsplit

/// The seam the app target drives to move a surface between panes, workspaces,
/// and windows, and to enumerate the existing-workspace destinations a surface
/// can move to.
///
/// Conformed by ``PaneSurfaceMoveCoordinator`` and injected at the composition
/// root so app surfaces (the terminal NSView submenu, the bonsplit context menu,
/// drop targets, the control socket) call one owner instead of the legacy
/// `AppDelegate.moveSurface`/`moveBonsplitTab`/`workspaceMoveTargets` methods.
/// The coordinator resolves the move/target decision and applies the irreducible
/// live mutations through ``PaneSurfaceMoveHosting``; the seam exposes only the
/// value-typed request/result.
///
/// `@MainActor` because surface movement is a main-actor UI flow (menu / drop /
/// socket action) and the coordinator co-locates with the live workspace state it
/// drives.
@MainActor
public protocol PaneLayoutControlling: AnyObject {
    /// Moves the surface described by `request` into its target pane / workspace,
    /// returning whether the move succeeded. Mirrors the legacy
    /// `AppDelegate.moveSurface(panelId:toWorkspace:targetPane:targetIndex:
    /// splitTarget:focus:focusWindow:)`.
    @discardableResult
    func move(surface request: PaneSurfaceMoveRequest) -> Bool

    /// Moves the existing bonsplit tab `tabId` into `targetWorkspaceId` (resolving
    /// the tab to its panel id first), returning whether the move succeeded.
    /// Mirrors the legacy `AppDelegate.moveBonsplitTab(tabId:toWorkspace:
    /// targetPane:targetIndex:splitTarget:focus:focusWindow:)`.
    @discardableResult
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID?,
        targetIndex: Int?,
        splitTarget: PaneSurfaceMoveRequest.SplitTarget?,
        focus: Bool,
        focusWindow: Bool
    ) -> Bool

    /// The existing-workspace move targets for the given reference window and
    /// already-ordered/labelled window summaries, excluding `excludingWorkspaceId`.
    /// Mirrors the move-target loop of the legacy
    /// `AppDelegate.workspaceMoveTargets(excludingWorkspaceId:referenceWindowId:)`;
    /// the window ordering and localized labels are resolved app-side and supplied
    /// in `summaries`.
    func moveTargets(
        for summaries: [PaneSurfaceMoveWindowSummary],
        excludingWorkspaceId: UUID?
    ) -> [WorkspaceMoveTarget]
}
