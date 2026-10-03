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
        guard let bridge, let hit = hit(screenPoint: screenPoint) else { return nil }
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
/// workspace switch mid-drag is picked up.
final class LayoutTabDropTarget: TabDropTargetProviding {
    private weak var window: WindowController?
    private weak var touched: LayoutRootView?

    init(window: WindowController) {
        self.window = window
    }

    var layoutView: LayoutRootView? { window?.content?.layoutView }

    func dropHitTest(screenPoint: CGPoint, payload: TabDragPayload) -> TabDropProposal? {
        guard let content = window?.content, let layout = content.layoutView, let nsWindow = layout.window else { return nil }
        let windowPoint = nsWindow.convertPoint(fromScreen: screenPoint)
        guard layout.bounds.contains(layout.convert(windowPoint, from: nil)) else {
            dropExited()
            return nil
        }
        if touched !== layout { touched?.cancelTabDrag() }
        touched = layout
        guard let target = layout.updateTabDrag(LayoutTabID(payload.dragID), locationInWindow: windowPoint) else { return nil }
        let point = CGRect(origin: screenPoint, size: .zero).insetBy(dx: -1, dy: -1)
        switch target {
        case .pane(let pane, .center):
            guard let controller = content.panes[pane] else { return nil }
            // A tab dropped on its own pane keeps its tab group (the end of
            // its own strip is not a group change).
            let ownGroup: String? = if case .tab(let id, _) = payload {
                controller.stripModel.orderedTabs.first { $0.id.rawValue == id }?.groupID?.rawValue
            } else { nil }
            return TabDropProposal(kind: .strip(stripID: controller.stripModel.stripID, index: controller.pane.tabs.count, groupID: ownGroup),
                                   highlightFrame: screenFrame(of: pane, in: layout) ?? point)
        case .pane(let pane, let zone):
            guard let edge = zone.edge else { return nil }
            return TabDropProposal(kind: .newSplit(paneID: pane.rawValue, edge: edge),
                                   highlightFrame: screenFrame(of: pane, in: layout).map { Self.half($0, edge: edge) } ?? point)
        case .newColumn(let screen, let after):
            return TabDropProposal(kind: .newColumn(screenID: screen.rawValue, afterColumnID: after?.rawValue), highlightFrame: point)
        case .newDock(let screen, let edge):
            return TabDropProposal(kind: .newDock(screenID: screen.rawValue, edge: edge.rawValue), highlightFrame: point)
        }
    }

    func dropExited() {
        touched?.cancelTabDrag()
        touched = nil
    }

    func dropEnded(committed: TabDropProposal?) {
        dropExited()
    }

    private func screenFrame(of pane: LayoutPaneID, in layout: LayoutRootView) -> CGRect? {
        guard let rect = layout.frame(of: pane), let window = layout.window else { return nil }
        return window.convertToScreen(layout.convert(rect, to: nil))
    }

    /// The half of `rect` (screen space, y up) a split on `edge` would take.
    static func half(_ rect: CGRect, edge: TabDropEdge) -> CGRect {
        switch edge {
        case .left: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .bottom: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        }
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
