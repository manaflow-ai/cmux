import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSidebar

// `TabDropTargetProviding` adapters for the two surfaces whose drag APIs
// predate the protocol. Tab strips conform directly. One pair per window,
// cached by the session for the whole drag.

/// The sidebar: workspace rows (with spring-load), gaps (new workspace), the
/// "new" button, and collapsed groups. Spring-load and auto-scroll run in
/// the sidebar itself.
final class SidebarTabDropTarget: TabDropTargetProviding {
    private weak var bridge: SidebarBridge?
    private var active = false
    /// Machine of the dragged tabs or workspaces; drops stay on it.
    var sourceMachine: MachineID = .local
    /// The last sidebar drop this target proposed, in sidebar terms, so a
    /// drag that moves its whole workspace reuses the row-drag reorder path.
    private(set) var lastDrop: SidebarTabDrop?
    var bridgeForDrop: SidebarBridge? { bridge }

    init(bridge: SidebarBridge) {
        self.bridge = bridge
    }

    /// The raw sidebar hit (opens a gap, lights a row or group).
    func hit(screenPoint: CGPoint) -> SidebarTabDropHit? {
        guard let bridge, let hit = bridge.container.sidebarView.tabDragUpdate(screenPoint: screenPoint, sourceMachine: sourceMachine) else {
            return nil
        }
        active = true
        return hit
    }

    func dropHitTest(screenPoint: CGPoint, payload: TabDragPayload) -> TabDropProposal? {
        guard let bridge else { return nil }
        guard let hit = hit(screenPoint: screenPoint) else {
            // A row that refuses the tab still previews, with why (tab-dnd).
            lastDrop = nil
            guard let refusal = bridge.container.sidebarView.tabDragRefusal(screenPoint: screenPoint, sourceMachine: sourceMachine) else {
                return nil
            }
            active = true
            return TabDropProposal(kind: .newWorkspace(groupID: nil, index: -1), highlightFrame: refusal.highlightFrame,
                                   refusedReason: refusal.text)
        }
        lastDrop = hit.drop
        let kind: TabDropKind
        switch hit.drop {
        case .intoWorkspace(let id):
            kind = .workspace(id: id.rawValue)
        case .newWorkspace(let section, let group, let index):
            let root = bridge.daemonRootIndex(for: DropPosition(section: section, group: group, index: index),
                                              moving: [], in: bridge.model.sections)
            kind = .newWorkspace(groupID: group?.rawValue, index: root ?? -1)
        case .intoGroup(let group):
            kind = .newWorkspace(groupID: group.rawValue, index: -1)
        }
        return TabDropProposal(kind: kind, highlightFrame: hit.highlightFrame)
    }

    func dropExited() {
        guard active else { return }
        active = false
        bridge?.container.sidebarView.tabDragExited()
    }

    func dropEnded(committed: TabDropProposal?) {
        active = false
        bridge?.container.sidebarView.tabDragEnded()
    }
}

/// The workspace layout: pane edge zones (new split), pane centers (join
/// that pane's strip at the end), and column gaps (new strip column). Reads
/// the window's current content on every call, so a spring-loaded
/// workspace switch mid-drag is picked up. It answers for every point of
/// its window that no surface before it took (the title bar, the window
/// edges): the point is moved to the nearest point of the layout, so a
/// drop anywhere in a window previews and lands somewhere (tab-dnd).
final class LayoutTabDropTarget: TabDropTargetProviding {
    private weak var window: WindowController?
    private weak var touched: LayoutRootView?
    /// The layout pane the drag empties (it closes in the same step): the
    /// split room is decided with it, once, and the commit runs that.
    var removingPane: LayoutPaneID?

    init(window: WindowController) {
        self.window = window
    }

    var layoutView: LayoutRootView? { window?.content?.layoutView }

    func dropHitTest(screenPoint: CGPoint, payload: TabDragPayload) -> TabDropProposal? {
        proposal(screenPoint: screenPoint, dragKey: payload.dragID) { controller in
            // A tab dropped on its own pane keeps its tab group (the end of
            // its own strip is not a group change).
            guard case .tab(let id, _) = payload else { return nil }
            return controller.stripModel.orderedTabs.first { $0.id.rawValue == id }?.groupID?.rawValue
        }
    }

    /// A sidebar workspace over this layout (`TabDragSession+Workspaces`):
    /// the same pane targets as a tab, but only inside the layout (the
    /// rest of the window keeps the workspace's own drops). Its tabs join
    /// no tab group.
    func workspaceHitTest(screenPoint: CGPoint, workspaceID: String) -> TabDropProposal? {
        guard let layout = layoutView, let nsWindow = layout.window,
              layout.bounds.contains(layout.convert(nsWindow.convertPoint(fromScreen: screenPoint), from: nil)) else { return nil }
        return proposal(screenPoint: screenPoint, dragKey: workspaceID) { _ in nil }
    }

    /// The layout's target under `screenPoint` for a drag keyed `dragKey`;
    /// `ownGroup` is the group a center drop on `controller` keeps.
    private func proposal(screenPoint: CGPoint, dragKey: String,
                          ownGroup: (PaneController) -> String?) -> TabDropProposal? {
        guard let content = window?.content, let layout = content.layoutView, let nsWindow = layout.window,
              !layout.bounds.isEmpty else { return nil }
        let local = layout.convert(nsWindow.convertPoint(fromScreen: screenPoint), from: nil)
        let inside = layout.bounds.insetBy(dx: 0.5, dy: 0.5)
        let clamped = CGPoint(x: min(max(local.x, inside.minX), inside.maxX), y: min(max(local.y, inside.minY), inside.maxY))
        let windowPoint = layout.convert(clamped, to: nil)
        if touched !== layout { touched?.cancelTabDrag() }
        touched = layout
        guard let target = layout.updateTabDrag(LayoutTabID(dragKey), locationInWindow: windowPoint, removing: removingPane) else {
            return nil
        }
        // The ghost lands on the rect the layout's preview shows (R47).
        let preview = layout.tabDragHighlightOnScreen ?? CGRect(origin: screenPoint, size: .zero).insetBy(dx: -1, dy: -1)
        switch target {
        case .pane(let pane, .center):
            guard let controller = content.panes[pane] else { return nil }
            return TabDropProposal(kind: .strip(stripID: controller.stripModel.stripID, index: controller.pane.tabs.count,
                                                groupID: ownGroup(controller)),
                                   highlightFrame: preview)
        case .pane(let pane, let zone):
            guard let edge = zone.edge else { return nil }
            return TabDropProposal(kind: .newSplit(paneID: pane.rawValue, edge: edge), highlightFrame: preview)
        case .newColumn(let screen, let after):
            return TabDropProposal(kind: .newColumn(screenID: screen.rawValue, afterColumnID: after?.rawValue), highlightFrame: preview)
        case .newDock(let screen, let edge):
            return TabDropProposal(kind: .newDock(screenID: screen.rawValue, edge: edge.rawValue), highlightFrame: preview)
        }
    }

    /// Outlines a strip's insert slot (`screenRect`) in this layout's
    /// overlay, so one outline moves between pane zones and strip slots.
    func outline(screenRect: CGRect) {
        guard let layout = layoutView else { return }
        if touched !== layout { touched?.cancelTabDrag() }
        touched = layout
        layout.showTabDragOutline(screenRect: screenRect)
    }

    /// Labels the layout's preview: the refusal reason, or the stay note.
    func note(_ text: String, refused: Bool) {
        touched?.setTabDragNote(text, refused: refused)
    }

    func dropExited() {
        touched?.cancelTabDrag()
        touched = nil
    }

    func dropEnded(committed: TabDropProposal?) {
        dropExited()
    }
}

extension PaneDropZone {
    var edge: TabDropEdge? {
        switch self {
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        case .center: nil
        }
    }
}

extension TabDragPayload {
    /// Tab or group id, for surfaces that key a drag by one string.
    var dragID: String {
        switch self {
        case .tab(let id, _): id
        case .tabGroup(let id, _, _, _): id
        }
    }
}
