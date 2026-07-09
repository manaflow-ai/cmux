import Bonsplit
import CmuxWorkspaces
import Foundation

/// `Workspace` is the live host for its ``PanelFocusNavigationCoordinator``.
/// Each witness reproduces the reads and side effects the legacy `Workspace`
/// bonsplit-navigation bodies (`moveFocus`, `selectNextSurface`,
/// `selectPreviousSurface`, `selectSurface(at:)`, `selectLastSurface`) performed
/// inline against the `BonsplitController` split tree, the `any Panel` registry,
/// the `applyTabSelection` chain, and the canvas layout model. The coordinator
/// owns the navigation orchestration; these witnesses are the app-target-typed
/// primitives it drives. The coordinator references this host weakly, so there is
/// no retain cycle.
extension Workspace: PanelFocusNavigationHosting {
    // MARK: Canvas-layout gestures

    var panelFocusNavIsCanvasLayout: Bool {
        layoutMode == .canvas
    }

    func panelFocusNavMoveCanvasFocus(direction: NavigationDirection) {
        moveCanvasFocus(direction: direction)
    }

    func panelFocusNavSelectAdjacentCanvasTab(offset: Int) -> Bool {
        selectAdjacentCanvasTab(offset: offset)
    }

    // MARK: Pane focus

    var panelFocusNavFocusedPanelId: UUID? {
        focusedPanelId
    }

    func panelFocusNavUnfocusPanel(panelId: UUID) {
        if let prev = panels[panelId] {
            prev.unfocus()
        }
    }

    func panelFocusNavNavigateFocus(direction: NavigationDirection) {
        bonsplitController.navigateFocus(direction: direction)
    }

    // MARK: Bonsplit focused-pane / tab reads

    var panelFocusNavFocusedPaneId: PaneID? {
        bonsplitController.focusedPaneId
    }

    func panelFocusNavSelectedTabId(inPane paneId: PaneID) -> TabID? {
        bonsplitController.selectedTab(inPane: paneId)?.id
    }

    func panelFocusNavTabIds(inPane paneId: PaneID) -> [TabID] {
        bonsplitController.tabs(inPane: paneId).map(\.id)
    }

    // MARK: Bonsplit tab selection mutations

    func panelFocusNavSelectNextTab() {
        bonsplitController.selectNextTab()
    }

    func panelFocusNavSelectPreviousTab() {
        bonsplitController.selectPreviousTab()
    }

    func panelFocusNavSelectTab(_ tabId: TabID) {
        bonsplitController.selectTab(tabId)
    }

    // MARK: Selection reconcile

    func panelFocusNavApplyTabSelection(tabId: TabID, inPane paneId: PaneID) {
        applyTabSelection(tabId: tabId, inPane: paneId)
    }

    // MARK: Focus reconcile

    var panelFocusNavPortalRenderingEnabled: Bool {
        layoutFollowUpCoordinator.portalRenderingEnabled
    }

    func panelFocusNavScheduleAfterCurrentTurn(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            work()
        }
    }

    func panelFocusNavNoteScheduleDuringDetach() {
        #if DEBUG
        if isDetachingCloseTransaction {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
        #endif
    }

    func panelFocusNavPanelId(fromSurfaceId surfaceId: TabID) -> UUID? {
        panelIdFromSurfaceId(surfaceId)
    }

    func panelFocusNavSurfaceId(fromPanelId panelId: UUID) -> TabID? {
        surfaceIdFromPanelId(panelId)
    }

    func panelFocusNavPanelExists(panelId: UUID) -> Bool {
        panels[panelId] != nil
    }

    var panelFocusNavAllPaneIds: [PaneID] {
        bonsplitController.allPaneIds
    }

    var panelFocusNavAllPanelIds: [UUID] {
        Array(panels.keys)
    }

    func panelFocusNavFocusPane(_ paneId: PaneID) {
        bonsplitController.focusPane(paneId)
    }

    func panelFocusNavUnfocusAllExcept(panelId targetPanelId: UUID) {
        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }
    }

    func panelFocusNavFocusPanel(panelId: UUID) {
        panels[panelId]?.focus()
    }

    func panelFocusNavEnsureTerminalFocus(panelId: UUID) {
        if let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: panelId)
        }
    }

    func panelFocusNavApplyFocusedPanelDirectory(panelId: UUID) {
        if let dir = panelDirectories[panelId] {
            currentDirectory = dir
        }
    }

    func panelFocusNavApplyFocusedPanelGitBranch(panelId: UUID) {
        gitBranch = panelGitBranches[panelId]
    }

    func panelFocusNavApplyFocusedPanelPullRequest(panelId: UUID) {
        pullRequest = panelPullRequests[panelId]
    }

    // MARK: Non-focus-split focus-reassert

    func panelFocusNavReassertFocusPanel(panelId: UUID, previousHostedView: AnyObject?) {
        focusPanel(panelId, previousHostedView: previousHostedView as? GhosttySurfaceScrollView)
    }

    // `panelFocusNavBeginNonFocusSplitFocusReassert` /
    // `panelFocusNavMatchesPendingNonFocusSplitFocusReassert` /
    // `panelFocusNavClearNonFocusSplitFocusReassert` satisfy the same protocol
    // but live in `Workspace.swift` because they touch the file-private
    // `surfaceRegistry` state machine.
}
