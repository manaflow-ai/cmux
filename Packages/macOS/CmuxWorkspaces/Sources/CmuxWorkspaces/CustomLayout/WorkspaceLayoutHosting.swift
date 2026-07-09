public import Foundation
public import Bonsplit

/// The workspace-side seam ``WorkspaceLayoutCoordinator`` drives the live split
/// tree and surface creation through when applying a cmux.json custom layout.
///
/// **Why a synchronous read-plus-side-effect protocol and not value snapshots.**
/// `applyCustomLayout` is a single MainActor turn that builds the split tree,
/// populates each leaf pane, then applies divider positions, exactly as the
/// legacy `Workspace` bodies did. Each step observes and mutates the
/// authoritative `BonsplitController` split tree and the workspace's panel set in
/// place: a freshly created split's second pane id is read back immediately, the
/// next leaf's placeholder surfaces are read from the just-built pane, and the
/// final divider pass walks the live `treeSnapshot()`. Routing these through a
/// synchronous seam preserves every in-turn ordering; an async value-snapshot
/// design would open suspension windows the legacy code never had.
///
/// Surface creation returns only the new panel id (`UUID`); the app-target panel
/// types (`TerminalPanel`/`BrowserPanel`/`ProjectPanel`) never cross into the
/// package. The startup-command send and its not-ready observer machinery stay
/// app-side (they touch `NotificationCenter`, the workspace panel registry, and
/// `TerminalPanel.sendInput`) and are reached through
/// ``sendStartupCommand(_:toTerminalPanelId:)``.
@MainActor
public protocol WorkspaceLayoutHosting: AnyObject {
    /// The root pane id of a freshly created workspace, or `nil` when the split
    /// controller has no panes (legacy `bonsplitController.allPaneIds.first`).
    func layoutRootPaneId() -> PaneID?

    /// The panel ids of the surfaces in a pane, in tab order, dropping tabs that
    /// map to no panel (legacy
    /// `bonsplitController.tabs(inPane:).compactMap { panelIdFromSurfaceId($0.id) }`).
    func layoutPanelIds(inPane paneId: PaneID) -> [UUID]

    /// Creates a placeholder terminal surface in a pane and returns its panel id
    /// (legacy `newTerminalSurface(inPane:focus:)`). Used as the split anchor when
    /// a pane has no existing surface.
    func layoutCreateTerminalSurface(inPane paneId: PaneID, focus: Bool) -> UUID?

    /// Creates a terminal surface in a pane with a working directory and startup
    /// environment, returning its panel id (legacy
    /// `newTerminalSurface(inPane:focus:workingDirectory:startupEnvironment:)`).
    func layoutCreateTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool,
        workingDirectory: String,
        startupEnvironment: [String: String]
    ) -> UUID?

    /// Splits off a new terminal pane from an anchor panel and returns the new
    /// panel id (legacy
    /// `newTerminalSplit(from:orientation:insertFirst:focus:)`).
    func layoutCreateTerminalSplit(
        fromPanelId panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool
    ) -> UUID?

    /// Creates a browser surface in a pane using the restoration creation policy
    /// and returns its panel id (legacy
    /// `newBrowserSurface(inPane:url:focus:creationPolicy: .restoration)`).
    func layoutCreateBrowserSurface(inPane paneId: PaneID, url: URL?, focus: Bool) -> UUID?

    /// Creates a project surface in a pane and returns its panel id (legacy
    /// `newProjectSurface(inPane:projectPath:focus:)`).
    func layoutCreateProjectSurface(inPane paneId: PaneID, projectPath: String, focus: Bool) -> UUID?

    /// The pane id owning the given panel id (legacy
    /// `Workspace.paneId(forPanelId:)`).
    func layoutPaneId(forPanelId panelId: UUID) -> PaneID?

    /// Closes a panel (legacy `closePanel(_:force:)`); the placeholder-replacement
    /// paths always pass `force: true`.
    func layoutClosePanel(_ panelId: UUID, force: Bool)

    /// Sets a panel's custom tab title (legacy
    /// `setPanelCustomTitle(panelId:title:)`).
    func layoutSetPanelCustomTitle(panelId: UUID, title: String)

    /// Sends a startup command to a terminal panel once its surface is ready,
    /// dropping it if the panel is not (or is no longer) a terminal panel (legacy
    /// `sendInputWhenReady(_:to:)` guarded by `terminalPanel(for:)`). The
    /// not-ready observer + timeout machinery stays app-side.
    func layoutSendStartupCommand(_ command: String, toTerminalPanelId panelId: UUID)

    /// Resolves a surface's declared cwd against the layout's base cwd (legacy
    /// `CmuxConfigStore.resolveCwd(_:relativeTo:)`).
    func layoutResolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String

    /// The current split-tree snapshot (legacy
    /// `bonsplitController.treeSnapshot()`).
    func layoutTreeSnapshot() -> ExternalTreeNode

    /// Applies an external divider position to a split (legacy
    /// `bonsplitController.setDividerPosition(_:forSplit:fromExternal: true)`).
    func layoutApplySplitDividerPosition(_ position: CGFloat, forSplit splitId: UUID)

    /// Focuses a panel (legacy `focusPanel(_:)`).
    func layoutFocusPanel(_ panelId: UUID)
}
