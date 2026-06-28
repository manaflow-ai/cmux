public import Foundation
public import Bonsplit

/// The workspace-side seam ``PanelFocusNavigationCoordinator`` drives for the
/// pane/surface focus-navigation effects it cannot own from the package: the
/// `BonsplitController` focus/tab reads and mutations, the post-navigation
/// `applyTabSelection` reconcile chain, the per-panel `unfocus()` over the
/// app-target panel registry, and the canvas-layout focus/tab gestures.
///
/// **Why thin synchronous witnesses, not value snapshots.** Each navigation
/// gesture (Cmd-arrow move-focus, next/prev/index/last surface) is one MainActor
/// turn: it reads the live `BonsplitController` focused pane + selected tab,
/// mutates the split tree's focus or selection in place, and re-reads the now
/// authoritative selection to reconcile AppKit first responder, exactly as the
/// legacy `Workspace` bodies did inline. Routing these through synchronous
/// witnesses preserves every in-turn ordering; an async snapshot design would
/// open suspension windows the legacy navigation never had. These gestures are
/// keyboard/menu/CLI driven, never per-frame.
///
/// **What stays here vs. in the coordinator.** The coordinator owns the
/// navigation *orchestration*: the canvas-vs-splits branch, the unfocus-then-
/// navigate ordering, and the read-mutate-reconcile shape shared across all five
/// methods. This host owns the *primitives that hold app-target types*: the
/// `BonsplitController` (Bonsplit), the `any Panel` registry walk for
/// `unfocus()`, the `applyTabSelection` side-effect chain, and the
/// `WorkspaceLayoutMode`/canvas-model gestures. The coordinator never names an
/// app type; it calls these witnesses.
///
/// `@MainActor` for the same reason as the coordinator: every effect is one
/// main-actor turn driven by a keyboard/menu/CLI gesture, so the host lives where
/// its callers live and no bridging is needed. Held weakly by the coordinator
/// (``PanelFocusNavigationCoordinator/attach(host:)``); `Workspace` owns the
/// coordinator, so a strong back-reference would be a retain cycle.
@MainActor
public protocol PanelFocusNavigationHosting: AnyObject {
    // MARK: Canvas-layout gestures

    /// Whether the workspace is in canvas layout (legacy `layoutMode == .canvas`).
    /// When true, move-focus and adjacent-surface selection route to the canvas
    /// model instead of the split tree.
    var panelFocusNavIsCanvasLayout: Bool { get }

    /// Moves focus within the canvas layout in `direction` (legacy
    /// `Workspace.moveCanvasFocus(direction:)`).
    func panelFocusNavMoveCanvasFocus(direction: NavigationDirection)

    /// Selects the canvas tab `offset` positions from the focused canvas pane's
    /// current tab, returning whether a tab was selected (legacy
    /// `Workspace.selectAdjacentCanvasTab(offset:)`). When false the caller falls
    /// through to the split-tree tab navigation.
    func panelFocusNavSelectAdjacentCanvasTab(offset: Int) -> Bool

    // MARK: Pane focus

    /// The currently focused panel's id (legacy `Workspace.focusedPanelId`), read
    /// before a move so the previously focused panel can be unfocused.
    var panelFocusNavFocusedPanelId: UUID? { get }

    /// Unfocuses the panel with `panelId` when it still exists in the panel
    /// registry (legacy `panels[prevPanelId]?.unfocus()`). No-op when the panel is
    /// gone.
    func panelFocusNavUnfocusPanel(panelId: UUID)

    /// Navigates the split-tree focus in `direction` (legacy
    /// `bonsplitController.navigateFocus(direction:)`).
    func panelFocusNavNavigateFocus(direction: NavigationDirection)

    // MARK: Bonsplit focused-pane / tab reads

    /// The focused pane id in the split tree (legacy
    /// `bonsplitController.focusedPaneId`).
    var panelFocusNavFocusedPaneId: PaneID? { get }

    /// The selected tab id in `paneId`, if any (legacy
    /// `bonsplitController.selectedTab(inPane:)?.id`).
    func panelFocusNavSelectedTabId(inPane paneId: PaneID) -> TabID?

    /// The ordered tab ids in `paneId` (legacy
    /// `bonsplitController.tabs(inPane:).map(\.id)`), used for index/last
    /// selection.
    func panelFocusNavTabIds(inPane paneId: PaneID) -> [TabID]

    // MARK: Bonsplit tab selection mutations

    /// Selects the next tab in the focused pane (legacy
    /// `bonsplitController.selectNextTab()`).
    func panelFocusNavSelectNextTab()

    /// Selects the previous tab in the focused pane (legacy
    /// `bonsplitController.selectPreviousTab()`).
    func panelFocusNavSelectPreviousTab()

    /// Selects the tab `tabId` (legacy `bonsplitController.selectTab(_:)`).
    func panelFocusNavSelectTab(_ tabId: TabID)

    // MARK: Selection reconcile

    /// Runs the full `applyTabSelection` side-effect chain for `tabId` in
    /// `paneId` (legacy `Workspace.applyTabSelection(tabId:inPane:)` with its
    /// default `reassertAppKitFocus`), keeping AppKit first responder and the
    /// bonsplit-selected tab aligned after a navigation.
    func panelFocusNavApplyTabSelection(tabId: TabID, inPane paneId: PaneID)

    // MARK: Focus reconcile

    /// Whether portal rendering is currently enabled (legacy
    /// `Workspace.layoutFollowUpCoordinator.portalRenderingEnabled`). Both the
    /// reconcile and the schedule are inert when false, matching the legacy
    /// early-return guards.
    var panelFocusNavPortalRenderingEnabled: Bool { get }

    /// Hops `work` to the next main-queue turn (legacy
    /// `DispatchQueue.main.async`), letting bonsplit selection/pane mutations
    /// settle before the coalesced reconcile runs. Byte-faithful main-queue
    /// deferral; the app target owns the dispatch.
    func panelFocusNavScheduleAfterCurrentTurn(_ work: @escaping @MainActor () -> Void)

    /// Records the DEBUG-only "schedule arrived during a detaching close
    /// transaction" diagnostic counter (legacy `#if DEBUG` increment of
    /// `Workspace.debugFocusReconcileScheduledDuringDetachCount` guarded by
    /// `isDetachingCloseTransaction`). No-op in release builds and when not
    /// detaching; the counter stays app-side because tests read it off
    /// `Workspace`.
    func panelFocusNavNoteScheduleDuringDetach()

    /// Maps a surface (tab) id to its owning panel id, if any (legacy
    /// `Workspace.panelIdFromSurfaceId(_:)`).
    func panelFocusNavPanelId(fromSurfaceId surfaceId: TabID) -> UUID?

    /// Maps a panel id to its surface (tab) id, if any (legacy
    /// `Workspace.surfaceIdFromPanelId(_:)`).
    func panelFocusNavSurfaceId(fromPanelId panelId: UUID) -> TabID?

    /// Whether a panel with `panelId` exists in the registry (legacy
    /// `panels[panelId] != nil`).
    func panelFocusNavPanelExists(panelId: UUID) -> Bool

    /// All pane ids in the split tree (legacy `bonsplitController.allPaneIds`).
    var panelFocusNavAllPaneIds: [PaneID] { get }

    /// All panel ids in the registry (legacy `panels.keys`). `.first` is the
    /// reconcile fallback target, matching the legacy `panels.keys.first`.
    var panelFocusNavAllPanelIds: [UUID] { get }

    /// Focuses the pane `paneId` in the split tree (legacy
    /// `bonsplitController.focusPane(_:)`).
    func panelFocusNavFocusPane(_ paneId: PaneID)

    /// Unfocuses every registered panel except `panelId` (legacy
    /// `for (panelId, panel) in panels where panelId != targetPanelId { panel.unfocus() }`).
    func panelFocusNavUnfocusAllExcept(panelId: UUID)

    /// Focuses the panel `panelId` (legacy `targetPanel.focus()`).
    func panelFocusNavFocusPanel(panelId: UUID)

    /// Ensures the AppKit first responder converges onto the focused terminal
    /// surface for `panelId` when it is a terminal panel (legacy
    /// `terminalPanel.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)`).
    /// No-op for non-terminal panels. The workspace id is supplied app-side.
    func panelFocusNavEnsureTerminalFocus(panelId: UUID)

    /// Applies the focused panel's recorded directory to the workspace's
    /// `currentDirectory`, only when a directory is recorded (legacy
    /// `if let dir = panelDirectories[targetPanelId] { currentDirectory = dir }`).
    func panelFocusNavApplyFocusedPanelDirectory(panelId: UUID)

    /// Applies the focused panel's recorded git-branch state to the workspace's
    /// `gitBranch` (legacy `gitBranch = panelGitBranches[targetPanelId]`),
    /// including clearing it to `nil` when none is recorded.
    func panelFocusNavApplyFocusedPanelGitBranch(panelId: UUID)

    /// Applies the focused panel's recorded pull-request state to the
    /// workspace's `pullRequest` (legacy
    /// `pullRequest = panelPullRequests[targetPanelId]`), including clearing it
    /// to `nil` when none is recorded.
    func panelFocusNavApplyFocusedPanelPullRequest(panelId: UUID)
}
