import AppKit
import CmuxNextBridge
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextSidebar
import CmuxNextTabs

// `TabDropTargetProviding` adapters for the two surfaces whose drag APIs
// predate the protocol. Tab strips conform directly. One pair per window,
// cached by the session for the whole drag.

/// The sidebar: workspace rows (with spring-load), gaps (new workspace), the
/// "new" button, collapsed groups, and a tab row's edge (before that tab).
/// Spring-load and auto-scroll run in the sidebar itself.
final class SidebarTabDropTarget: TabDropTargetProviding {
    private weak var bridge: SidebarBridge?
    /// The sidebar's window, whose strips take a tab dropped on a tab row's edge.
    private weak var window: WindowController?
    private var active = false
    /// Machine of the dragged tabs or workspaces; drops stay on it.
    var sourceMachine: MachineID = .local
    /// The last sidebar drop this target proposed, in sidebar terms, so a
    /// drag that moves its whole workspace reuses the row-drag reorder path.
    private(set) var lastDrop: SidebarTabDrop?
    var bridgeForDrop: SidebarBridge? { bridge }

    init(bridge: SidebarBridge, window: WindowController? = nil) {
        self.bridge = bridge
        self.window = window
    }

    /// The raw sidebar hit (opens a gap, lights a row or group). A tab drag
    /// `reordersTabRows`: a tab row's edge is that tab's slot.
    func hit(screenPoint: CGPoint, reordersTabRows: Bool = false) -> SidebarTabDropHit? {
        guard let bridge, let hit = bridge.container.sidebarView.tabDragUpdate(screenPoint: screenPoint, sourceMachine: sourceMachine,
                                                                                reordersTabRows: reordersTabRows) else {
            return nil
        }
        active = true
        return hit
    }

    func dropHitTest(screenPoint: CGPoint, payload: TabDragPayload) -> TabDropProposal? {
        guard let bridge else { return nil }
        guard let hit = hit(screenPoint: screenPoint, reordersTabRows: true) else {
            // A row that refuses the tab still previews, with why (tab-dnd).
            lastDrop = nil
            guard let refusal = bridge.container.sidebarView.tabDragRefusal(screenPoint: screenPoint, sourceMachine: sourceMachine,
                                                                                       reordersTabRows: true) else {
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
        case .beforeTab(let workspace, let tab):
            kind = beforeTab(StripTabID(tab.rawValue), workspace: workspace.rawValue, payload: payload)
        }
        return TabDropProposal(kind: kind, highlightFrame: hit.highlightFrame)
    }

    /// A tab row's edge: the tab's strip at that tab's slot, as a drop on the
    /// strip itself (rapid-switch item 3). A workspace this window doesn't
    /// show has no strip: the tab joins that workspace.
    private func beforeTab(_ tab: StripTabID, workspace: String, payload: TabDragPayload) -> TabDropKind {
        guard let pane = window?.content?.panes.values.first(where: { $0.tab(tab) != nil }),
              let index = pane.orderedIDs.firstIndex(of: tab) else { return .workspace(id: workspace) }
        let moving: String = switch payload {
        case .tab(let id, _): id
        case .tabGroup(_, let ids, _, _): ids.first ?? ""
        }
        // A strip index is the dragged tab's final slot: from earlier in the
        // same strip, the tab's own slot closes up first.
        let from = pane.orderedIDs.firstIndex(of: StripTabID(moving))
        let group = pane.stripModel.orderedTabs[index].groupID?.rawValue
        return .strip(stripID: pane.stripModel.stripID, index: from.map { $0 < index ? index - 1 : index } ?? index, groupID: group)
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

    /// When the pane edge under a resting pointer arms its split; nil when none is pending.
    var dwellDeadline: CFTimeInterval? { touched?.tabDragDwellDeadline }

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
        guard let content = window?.content, case let layout = content.layoutView, let nsWindow = layout.window,
              !layout.bounds.isEmpty else { return nil }
        let local = layout.convert(nsWindow.convertPoint(fromScreen: screenPoint), from: nil)
        let inside = layout.bounds.insetBy(dx: 0.5, dy: 0.5)
        let clamped = CGPoint(x: min(max(local.x, inside.minX), inside.maxX), y: min(max(local.y, inside.minY), inside.maxY))
        let windowPoint = layout.convert(clamped, to: nil)
        if touched !== layout { touched?.cancelTabDrag() }
        touched = layout
        guard let target = layout.updateTabDrag(LayoutTabID(dragKey), locationInWindow: windowPoint, removing: removingPane,
                                                edgeDwell: DragTunables.splitDwell.value) else {
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

    /// Hides the preview of a zone the drag cannot take (it draws nothing).
    func hideOutline() {
        touched?.hideTabDragHighlight()
    }

    /// Labels the layout's preview: the stay note.
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
