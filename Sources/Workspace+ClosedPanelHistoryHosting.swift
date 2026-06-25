import Bonsplit
import CmuxPanes
import CmuxWorkspaces
import Foundation

/// `Workspace` is the live host for its `ClosedPanelHistoryCoordinator`. Every
/// member reads or drives the authoritative `BonsplitController` split tree and
/// the workspace's live panel graph, reproducing the reads/writes the legacy
/// closed-panel-history bodies performed inline. The panel/snapshot creation that
/// touches the app-target `Panel`/`TerminalPanel`/`BrowserPanel` types and the
/// `RestorableAgentSessionIndex` stays here, behind the seam. The coordinator is
/// held by `Workspace` and references this host weakly, so there is no retain
/// cycle.
extension Workspace: WorkspaceClosedPanelHistoryHosting {
    var closedPanelHistoryWorkspaceId: UUID {
        id
    }

    // `tabs(inPane:)`, `allBonsplitPaneIds`, `panelIdFromSurfaceId(_:)`,
    // `surfaceIdFromPanelId(_:)`, `paneId(forPanelId:)`, `focusPanel(_:)`, and
    // `triggerFocusFlash(panelId:)` are already internal `Workspace` members (the
    // first two via `SurfaceLifecycleHosting`), so they satisfy the
    // `WorkspaceClosedPanelHistoryHosting` witnesses directly; only the members
    // below need an app-side adapter.

    func closedPanelHistoryTreeSnapshot() -> ExternalTreeNode {
        bonsplitController.treeSnapshot()
    }

    func selectedOrFirstTab(inPane paneId: PaneID) -> Bonsplit.Tab? {
        bonsplitController.selectedTab(inPane: paneId)
            ?? bonsplitController.tabs(inPane: paneId).first
    }

    func closedPanelAnchorPanelId(forClosedTabIndex closedTabIndex: Int, inPane paneId: PaneID) -> UUID? {
        // The neighbor-selection rule (prefer the next tab, fall back to the
        // previous, none when the closing tab is alone) lives in
        // SessionRestoreCoordinator; Workspace resolves the chosen tab's surface
        // id to its panel id against the live pane-tree state.
        let paneTabs = bonsplitController.tabs(inPane: paneId)
        return sessionRestoreCoordinator
            .paneAnchorNeighborIndex(forClosedTabIndex: closedTabIndex, tabCount: paneTabs.count)
            .flatMap { panelIdFromSurfaceId(paneTabs[$0].id) }
    }

    // `surfaceRegistryConsumeCloseHistoryEligibility` /
    // `surfaceRegistryClearCloseHistoryEligibility` are defined in
    // `Workspace.swift`, co-located with the `private surfaceRegistry` they read,
    // rather than here (this separate file cannot see that private member). They
    // still satisfy the seam witnesses.

    func pushClosedPanelHistory(_ entry: ClosedPanelHistoryEntry) {
        ClosedItemHistoryStore.shared.push(.panel(entry))
    }

    func buildClosedPanelSnapshot(panelId: UUID) -> SessionPanelSnapshot? {
        // Prefer the warm cached agent index over a synchronous
        // `RestorableAgentSessionIndex.load()` (sysctl-per-record + disk, ~350ms-1.8s on
        // machines with large agent history) so closing a tab does not freeze the main
        // thread. Fall back to a fresh load only when the cache has not loaded yet (the
        // brief window after launch before the first refresh completes; the cache is
        // prewarmed at launch so this is rare). A cached entry at most one refresh stale
        // is acceptable here because restore prefers the always-fresh in-memory
        // resumeBinding and only consults this agent snapshot when no binding exists, so
        // cmux-launched agents reopen correctly regardless of cache freshness.
        let agentIndex = hostEnvironment?.sharedLiveAgentIndex.currentIndexSchedulingRefresh()
            ?? RestorableAgentSessionIndex.load()
        let restorableAgent = agentIndex.snapshot(workspaceId: id, panelId: panelId)
        return sessionPanelSnapshot(
            panelId: panelId,
            includeScrollback: true,
            restorableAgent: restorableAgent,
            resumeBinding: effectiveSurfaceResumeBinding(
                panelId: panelId,
                surfaceResumeBindingIndex: nil
            )
        )
    }

    var focusedOrFirstPaneId: PaneID? {
        bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
    }

    func hasLivePanel(id: UUID) -> Bool {
        panels[id] != nil
    }

    func createPanel(from snapshot: SessionPanelSnapshot, inPane paneId: PaneID) -> UUID? {
        createPanel(from: snapshot, inPane: paneId, snapshotWorkspaceId: nil)
    }

    func reorderSurface(panelId: UUID, toIndex index: Int) {
        _ = reorderSurface(panelId: panelId, toIndex: index, focus: true)
    }

    func focusPaneSelectingPanel(_ pane: PaneID, panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        bonsplitController.focusPane(pane)
        bonsplitController.selectTab(tabId)
    }

    func newFallbackTerminalSplit(
        fromPanelId anchorPanelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool
    ) -> UUID? {
        newTerminalSplit(
            from: anchorPanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: false
        )?.id
    }

    func closePanel(_ panelId: UUID) {
        _ = closePanel(panelId, force: true)
    }
}
