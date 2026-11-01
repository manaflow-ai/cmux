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
/// "new" button and collapsed groups. Spring-load and auto-scroll run in the
/// sidebar itself.
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

    /// The raw sidebar hit (opens a gap, lights a row or group). `slotDwell`: a tab drag's slot
    /// between two rows opens only after `DragTunables.sidebarSlotDwell`; workspace and screen
    /// drags open it at once.
    func hit(screenPoint: CGPoint, slotDwell: CFTimeInterval = 0) -> SidebarTabDropHit? {
        guard let bridge, let hit = bridge.container.sidebarView.tabDragUpdate(screenPoint: screenPoint, sourceMachine: sourceMachine,
                                                                                slotDwell: slotDwell) else {
            return nil
        }
        active = true
        return hit
    }

    func dropHitTest(screenPoint: CGPoint, payload: TabDragPayload) -> TabDropProposal? {
        guard let bridge else { return nil }
        guard let hit = hit(screenPoint: screenPoint, slotDwell: DragTunables.sidebarSlotDwell.value) else {
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

    /// When the slot between two rows under a resting pointer opens its gap; nil when none is pending.
    var dwellDeadline: CFTimeInterval? { active ? bridge?.container.sidebarView.tabDragSlotDeadline : nil }

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
/// the workspace on screen under the point on every call (the focused one,
/// or one shown beside it), so a spring-loaded workspace switch mid-drag is
/// picked up. It answers for every point of
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

    /// When the pane edge under a resting pointer arms its split; nil when none is pending.
    var dwellDeadline: CFTimeInterval? { touched?.tabDragDwellDeadline }

    func dropHitTest(screenPoint: CGPoint, payload: TabDragPayload) -> TabDropProposal? {
        // A terminal tab's own pane: the facing edge of the pane beside it joins that pane (bonsplit, #22287).
        let source = window?.content(atScreen: screenPoint)?.panes.values.first { $0.pane.tabs.contains { $0.id == payload.dragID && $0.kind == .pty } }
        return proposal(screenPoint: screenPoint, dragKey: payload.dragID, joinsFrom: source?.layoutPaneID) {
            // A drop on the tabs' own pane body leaves them where they are (bonsplit, #22287).
            payload.ownPlace(in: $0.stripModel.orderedTabs)
        }
    }

    /// A sidebar workspace over this layout (`TabDragSession+Workspaces`):
    /// the same pane targets as a tab, but only inside the layout (the
    /// rest of the window keeps the workspace's own drops). Its tabs join
    /// no tab group.
    func workspaceHitTest(screenPoint: CGPoint, workspaceID: String) -> TabDropProposal? {
        guard let layout = window?.content(atScreen: screenPoint)?.layoutView, let nsWindow = layout.window,
              layout.bounds.contains(layout.convert(nsWindow.convertPoint(fromScreen: screenPoint), from: nil)) else { return nil }
        return proposal(screenPoint: screenPoint, dragKey: workspaceID) { _ in nil }
    }

    /// The layout's target under `screenPoint` for a drag keyed `dragKey`;
    /// `ownPlace` is the dragged tabs' display index and group in
    /// `controller` when they are in it: a center drop there keeps them.
    private func proposal(screenPoint: CGPoint, dragKey: String, joinsFrom: LayoutPaneID? = nil,
                          ownPlace: (PaneController) -> (index: Int, group: String?)?) -> TabDropProposal? {
        // The workspace under the point: with `sidebar.multiView`, one shown beside the focused one takes its drops.
        guard let content = window?.content(atScreen: screenPoint), case let layout = content.layoutView, let nsWindow = layout.window,
              !layout.bounds.isEmpty else { return nil }
        let local = layout.convert(nsWindow.convertPoint(fromScreen: screenPoint), from: nil)
        let inside = layout.bounds.insetBy(dx: 0.5, dy: 0.5)
        let clamped = CGPoint(x: min(max(local.x, inside.minX), inside.maxX), y: min(max(local.y, inside.minY), inside.maxY))
        let windowPoint = layout.convert(clamped, to: nil)
        if touched !== layout { touched?.cancelTabDrag() }
        touched = layout
        guard let target = layout.updateTabDrag(LayoutTabID(dragKey), locationInWindow: windowPoint, removing: removingPane,
                                                joinsFrom: joinsFrom, edgeDwell: DragTunables.splitDwell.value) else {
            return nil
        }
        // The ghost lands on the rect the layout's preview shows (R47).
        let preview = layout.tabDragHighlightOnScreen ?? CGRect(origin: screenPoint, size: .zero).insetBy(dx: -1, dy: -1)
        switch target {
        case .pane(let pane, .center):
            guard let controller = content.panes[pane] else { return nil }
            let own = ownPlace(controller) ?? (controller.pane.tabs.count, nil)
            return TabDropProposal(kind: .strip(stripID: controller.stripModel.stripID, index: own.index, groupID: own.group),
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
        guard let layout = window?.content(atScreen: CGPoint(x: screenRect.midX, y: screenRect.midY))?.layoutView else { return }
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

extension TabDragPayload {
    /// Tab or group id, for surfaces that key a drag by one string.
    var dragID: String {
        switch self {
        case .tab(let id, _): id
        case .tabGroup(let id, _, _, _): id
        }
    }
}
