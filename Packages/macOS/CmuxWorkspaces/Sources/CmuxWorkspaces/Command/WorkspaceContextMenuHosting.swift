public import Bonsplit
public import Foundation

/// The Workspace-side seam ``WorkspaceContextMenuCoordinator`` drives for the
/// bonsplit tab context-menu effects it cannot own from the package: the
/// surface-id ↔ panel-id resolution, surface creation/reorder/close, NSAlert
/// presentation (rename prompt, move-failure alert), the clipboard write of the
/// workspace/pane/surface identifiers, and the cross-workspace move targets that
/// live on the app-target `AppDelegate`.
///
/// The coordinator keeps the index/slicing math, the move-destination
/// prefix-encoding, and the per-action dispatch sequencing in the package; this
/// host carries each irreducible effect back into the app-target `Workspace` god
/// object where the panel registry, bonsplit controller, `AppDelegate`, and
/// AppKit alerts live.
///
/// `@MainActor` for the same reason as the sibling workspace coordinators: every
/// context-menu effect is one main-actor turn driven by a bonsplit menu action,
/// so the host lives where its callers live and no bridging is needed.
@MainActor
public protocol WorkspaceContextMenuHosting: AnyObject {
    /// The owning workspace's identifier, used when copying the
    /// workspace/pane/surface identifiers to the pasteboard.
    var workspaceId: UUID { get }

    // MARK: Surface ↔ panel resolution

    /// Resolves the panel id for a bonsplit surface id
    /// (`Workspace.panelIdFromSurfaceId`).
    func panelId(forSurfaceId surfaceId: TabID) -> UUID?
    /// The pane id that currently hosts `panelId` (`Workspace.paneId(forPanelId:)`).
    func paneId(forPanelId panelId: UUID) -> PaneID?

    // MARK: Close

    /// Closes the given tabs through the context-menu close path
    /// (`Workspace.closeTabsFromContextMenu(_:skipPinned:)`).
    func closeTabsFromContextMenu(_ tabIds: [TabID], skipPinned: Bool)

    // MARK: Surface creation / reorder

    /// The order index immediately to the right of `anchorTabId` in `paneId`
    /// (`Workspace.insertionIndexToRight`).
    func insertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int
    /// Creates a new terminal surface in `paneId`, inheriting the working
    /// directory from `sourcePanelId` when available, and returns its panel id
    /// (`Workspace.newTerminalSurface(...)`). Returns `nil` when creation fails.
    func newTerminalSurface(
        inPane paneId: PaneID,
        workingDirectoryFallbackSourcePanelId sourcePanelId: UUID?
    ) -> UUID?
    /// Creates a new browser surface in `paneId`, inheriting the profile of
    /// `anchorPanelId`, and returns its panel id (`Workspace.newBrowserSurface(...)`).
    /// Returns `nil` when creation fails.
    func newBrowserSurface(
        inPane paneId: PaneID,
        inheritingProfileFromPanelId anchorPanelId: UUID?
    ) -> UUID?
    /// Reorders `panelId` to `index` in its pane (`Workspace.reorderSurface`).
    func reorderSurface(panelId: UUID, toIndex index: Int)

    // MARK: Rename (NSAlert, app-target)

    /// Presents the rename-tab NSAlert for `tabId` and applies the entered title
    /// (`Workspace.promptRenamePanel`). The whole flow is app-side because it
    /// runs a modal NSAlert and reads the panel's current title from the
    /// app-target panel registry.
    func presentRenamePrompt(tabId: TabID)

    // MARK: Clipboard

    /// Copies the workspace/pane/surface identifiers for `surfaceId` to the
    /// general pasteboard (`Workspace.copyIdentifiersToPasteboard`).
    func copySurfaceIdentifiersToPasteboard(surfaceId: UUID)

    // MARK: Cross-workspace move (app-target AppDelegate)

    /// Whether `panelId` can be moved into a brand-new workspace
    /// (`AppDelegate.canMoveSurfaceToNewWorkspace(panelId:)`).
    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool
    /// The existing-workspace move targets for the bonsplit tab `tabId`
    /// (`AppDelegate.workspaceMoveTargets(forBonsplitTab:)`), mapped to the
    /// package value type.
    func workspaceMoveTargets(forBonsplitTab tabId: TabID) -> [WorkspaceContextMoveTarget]
    /// Moves `panelId` into a new workspace
    /// (`AppDelegate.moveSurfaceToNewWorkspace(panelId:focus:focusWindow:)`),
    /// returning whether the move succeeded.
    func moveSurfaceToNewWorkspace(panelId: UUID) -> Bool
    /// Moves `panelId` into the existing workspace `workspaceId`
    /// (`AppDelegate.moveSurface(panelId:toWorkspace:focus:focusWindow:)`),
    /// returning whether the move succeeded.
    func moveSurface(panelId: UUID, toWorkspace workspaceId: UUID) -> Bool

    // MARK: Move-failure alert (NSAlert, app-target)

    /// Presents the move-failed NSAlert (`Workspace.showMoveTabFailureAlert`).
    func presentMoveFailureAlert()
}
