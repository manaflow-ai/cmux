import Bonsplit
import CmuxPanes
import Foundation

/// `Workspace` is the live host for its ``SplitMoveReorderCoordinator``. Every
/// member either passes through to the authoritative `BonsplitController` split
/// tree or drives the workspace's own focus/selection/geometry reconcilers,
/// reproducing the calls the legacy Panel-Operations move/reorder bodies made
/// inline. The coordinator is held by `Workspace` and references this host
/// weakly, so there is no retain cycle.
///
/// `surfaceId(forPanelId:)`, `allBonsplitPaneIds`, and `tabs(inPane:)` are shared
/// witnesses with the ``SurfaceLifecycleHosting`` conformance, and `hasPanel(_:)`
/// is a shared witness with the `BrowserOpenWorkspaceHandle` conformance
/// (identical requirements); they are declared in those files and satisfy this
/// protocol from the single `Workspace` implementation. `paneId(forPanelId:)`,
/// `scheduleFocusReconcile()`, and `scheduleTerminalGeometryReconcile()` witness
/// directly from their existing `Workspace` methods. The two-argument
/// `applyTabSelection(tabId:inPane:)` and the single-argument `focusPanel(_:)`
/// witnesses below forward to the workspace's defaulted methods, so the
/// coordinator drives them with exactly the legacy default arguments.
extension Workspace: SplitMoveReorderHosting {
    var workspaceId: UUID { id }

    func panelId(forSurfaceId surfaceId: TabID) -> UUID? {
        panelIdFromSurfaceId(surfaceId)
    }

    // `hasPanel(_:)` is a shared witness with the `BrowserOpenWorkspaceHandle`
    // conformance (identical requirement); it satisfies this protocol from that
    // single `Workspace` implementation.

    var focusedBonsplitPaneId: PaneID? {
        bonsplitController.focusedPaneId
    }

    func selectedTab(inPane paneId: PaneID) -> Bonsplit.Tab? {
        bonsplitController.selectedTab(inPane: paneId)
    }

    func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
        bonsplitController.adjacentPane(to: paneId, direction: direction)
    }

    @discardableResult
    func moveTab(_ tabId: TabID, toPane paneId: PaneID, atIndex index: Int?) -> Bool {
        bonsplitController.moveTab(tabId, toPane: paneId, atIndex: index)
    }

    @discardableResult
    func reorderTab(_ tabId: TabID, toIndex index: Int) -> Bool {
        bonsplitController.reorderTab(tabId, toIndex: index)
    }

    func focusPane(_ paneId: PaneID) {
        bonsplitController.focusPane(paneId)
    }

    func selectTab(_ tabId: TabID) {
        bonsplitController.selectTab(tabId)
    }

    func focusPanel(_ panelId: UUID) {
        focusPanel(panelId, previousHostedView: nil, trigger: .standard, focusIntent: nil)
    }

    func applyTabSelection(tabId: TabID, inPane pane: PaneID) {
        applyTabSelection(
            tabId: tabId,
            inPane: pane,
            reassertAppKitFocus: true,
            focusIntent: nil,
            resumeHibernatedAgent: nil,
            previousTerminalHostedView: nil
        )
    }

    func mirrorTabReorder(current: [UUID], requested: [UUID]) -> [UUID]? {
        RemoteTmuxSessionMirror.mirrorTabReorder(current: current, requested: requested)
    }

    func setApplyingRemoteTmuxTabReorder(_ applying: Bool) {
        isApplyingRemoteTmuxTabReorder = applying
    }
}
