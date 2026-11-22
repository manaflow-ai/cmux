import CmuxNextDesign
import CmuxNextSidebar

/// A sidebar tab row's drag becomes the tab's own drag from its pane, so it
/// lands like a strip tab: another pane, another workspace's row, a sidebar
/// gap (new workspace), outside every window (new window).
enum SidebarTabRowHandoff {
    /// Installs both sidebar handoffs on `controller`: row drags
    /// (`installWorkspaceHandoff`) and tab row drags.
    static func install(on controller: WindowController, session: TabDragSession) {
        session.installWorkspaceHandoff(on: controller)
        controller.sidebar.container.onTabRowDrag = { [weak session] handoff in
            session.map { begin(handoff, session: $0) } ?? false
        }
    }

    /// False when another drag is running or the tab's workspace is not shown.
    static func begin(_ handoff: SidebarTabRowDragHandoff, session: TabDragSession) -> Bool {
        guard session.drag == nil, let paneModel = session.services.locateTab(handoff.tab.rawValue)?.1,
              let pane = session.services.paneController(for: paneModel) else { return false }
        let id = handoff.tab.rawValue
        session.begin(item: .tab(id), payload: .tab(id: id, sourceStripID: pane.stripModel.stripID), frame: handoff.rowScreenFrame,
                      grabOffset: handoff.grabOffset, point: handoff.screenPoint, image: nil, previewTab: id, draggedCount: 1, pane: pane)
        return true
    }
}
