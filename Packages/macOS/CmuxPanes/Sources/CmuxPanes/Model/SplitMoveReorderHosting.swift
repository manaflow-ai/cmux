public import Foundation
public import Bonsplit

/// The workspace-side seam ``SplitMoveReorderCoordinator`` drives the live split
/// tree and the workspace's surface bookkeeping through.
///
/// **Why a synchronous read/write protocol and not value snapshots.** Each
/// command lifted into the coordinator
/// (``SplitMoveReorderCoordinator/moveSurface(panelId:toPane:atIndex:focus:)``,
/// ``SplitMoveReorderCoordinator/moveSurfaceToAdjacentPane(panelId:direction:)``,
/// ``SplitMoveReorderCoordinator/reorderSurface(panelId:toIndex:focus:)``,
/// ``SplitMoveReorderCoordinator/reorderRemoteTmuxMirrorTabs(toPanelOrder:)``)
/// runs as one `@MainActor` turn that mutates the authoritative
/// `BonsplitController` split tree and then drives the workspace's own
/// focus/selection/geometry reconcilers, exactly as the legacy `Workspace`
/// bodies did. The split tree and per-pane tab order are owned by
/// `BonsplitController`; the surface-id-to-panel-id mapping, the focus and tab
/// selection orchestration, and the remote-tmux reorder suppression flag are
/// owned by the workspace. The coordinator reaches all of it through this seam
/// so it never holds the app-target `Workspace`, while every value it sees and
/// every side effect it triggers stay on the live state.
///
/// The seam speaks bonsplit value types (`PaneID`, `TabID`,
/// `NavigationDirection`, `Bonsplit.Tab`) directly because `CmuxPanes` already
/// depends on `Bonsplit`. The bonsplit pass-throughs mirror the legacy
/// `bonsplitController.*` calls one-for-one; the workspace pass-throughs mirror
/// the legacy `Workspace` helper calls (`surfaceIdFromPanelId`,
/// `panelIdFromSurfaceId`, `paneId(forPanelId:)`, `focusPanel`,
/// `applyTabSelection`, `scheduleFocusReconcile`,
/// `scheduleTerminalGeometryReconcile`) with their default arguments preserved
/// at the conformance.
@MainActor
public protocol SplitMoveReorderHosting: AnyObject {
    /// The owning workspace's identity, for DEBUG logging (legacy `Workspace.id`).
    var workspaceId: UUID { get }

    // MARK: Surface / pane resolution (legacy `Workspace` helpers)

    /// Resolves the bonsplit surface id owning the given panel id, or `nil`
    /// (legacy `Workspace.surfaceIdFromPanelId`).
    func surfaceId(forPanelId panelId: UUID) -> TabID?

    /// Resolves the panel id owning the given bonsplit surface id, or `nil`
    /// (legacy `Workspace.panelIdFromSurfaceId`).
    func panelId(forSurfaceId surfaceId: TabID) -> UUID?

    /// Resolves the pane id owning the given panel id, or `nil` (legacy
    /// `Workspace.paneId(forPanelId:)`).
    func paneId(forPanelId panelId: UUID) -> PaneID?

    /// Whether the workspace currently owns a panel with the given id (legacy
    /// `Workspace.panels[panelId] != nil`).
    func hasPanel(_ panelId: UUID) -> Bool

    // MARK: Bonsplit pass-throughs

    /// Every pane id (legacy `bonsplitController.allPaneIds`).
    var allBonsplitPaneIds: [PaneID] { get }

    /// The currently focused pane id (legacy
    /// `bonsplitController.focusedPaneId`).
    var focusedBonsplitPaneId: PaneID? { get }

    /// The pane's tabs in tab order (legacy `bonsplitController.tabs(inPane:)`).
    func tabs(inPane paneId: PaneID) -> [Bonsplit.Tab]

    /// The pane's selected tab (legacy `bonsplitController.selectedTab(inPane:)`).
    func selectedTab(inPane paneId: PaneID) -> Bonsplit.Tab?

    /// The adjacent pane in the given direction, or `nil` (legacy
    /// `bonsplitController.adjacentPane(to:direction:)`).
    func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID?

    /// Moves a surface tab into a pane, returning whether it took (legacy
    /// `bonsplitController.moveTab(_:toPane:atIndex:)`).
    @discardableResult
    func moveTab(_ tabId: TabID, toPane paneId: PaneID, atIndex index: Int?) -> Bool

    /// Reorders a surface tab to an index within its pane, returning whether it
    /// took (legacy `bonsplitController.reorderTab(_:toIndex:)`).
    @discardableResult
    func reorderTab(_ tabId: TabID, toIndex index: Int) -> Bool

    /// Focuses a pane (legacy `bonsplitController.focusPane(_:)`).
    func focusPane(_ paneId: PaneID)

    /// Selects a surface tab (legacy `bonsplitController.selectTab(_:)`).
    func selectTab(_ tabId: TabID)

    // MARK: Workspace orchestration hooks (legacy `Workspace` private helpers)

    /// Focuses a panel through the full workspace focus pipeline (legacy
    /// `Workspace.focusPanel(_:)` with its default arguments).
    func focusPanel(_ panelId: UUID)

    /// Applies a tab selection through the full workspace selection pipeline
    /// (legacy `Workspace.applyTabSelection(tabId:inPane:)` with its default
    /// arguments).
    func applyTabSelection(tabId: TabID, inPane pane: PaneID)

    /// Schedules a deferred focus reconcile (legacy
    /// `Workspace.scheduleFocusReconcile`).
    func scheduleFocusReconcile()

    /// Schedules a deferred terminal-geometry reconcile (legacy
    /// `Workspace.scheduleTerminalGeometryReconcile`).
    func scheduleTerminalGeometryReconcile()

    // MARK: Remote-tmux mirror reorder

    /// Computes the desired mirror-tab panel order, or `nil` when the tabs
    /// already match or cannot be reordered (legacy
    /// `RemoteTmuxSessionMirror.mirrorTabReorder(current:requested:)`).
    func mirrorTabReorder(current: [UUID], requested: [UUID]) -> [UUID]?

    /// Sets the flag that suppresses focus/selection churn while a remote-tmux
    /// mirror reorder is being applied (legacy
    /// `Workspace.isApplyingRemoteTmuxTabReorder`).
    func setApplyingRemoteTmuxTabReorder(_ applying: Bool)
}
