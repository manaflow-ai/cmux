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
}
