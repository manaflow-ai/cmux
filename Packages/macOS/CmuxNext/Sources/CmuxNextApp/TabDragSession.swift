import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextTabs

/// Takes over a tab dragged out of its strip (REWRITE.md "Tab drag"): one
/// drag, every destination. Hit-tests strips, the layout's drop zones, and
/// the sidebar in every window; releasing outside all windows tears the tab
/// off into a new window. Escape cancels. Every path ends the strip's
/// detached state (model change or `restoreDetachedTab`).
final class TabDragSession {
    private enum Target {
        case strip(PaneController, TabDropProposal)
        case layout(WindowController)
        case sidebar(WindowController)
        case outside
        case none
    }

    private struct Active {
        var tabID: StripTabID
        weak var source: PaneController?
        var payload: TabDragPayload
        var ghost: TabDragGhost
        var monitor: Any?
        var target: Target = .none
        var point: CGPoint
    }

    private unowned let services: AppServices
    private var active: Active?

    init(services: AppServices) {
        self.services = services
    }

    func begin(_ start: TabDragStart, from pane: PaneController) {
        if active != nil { finish(commit: false) }
        let ghost = TabDragGhost(image: start.snapshot?.cgImage, size: start.screenFrame.size, grabOffset: start.grabOffset)
        var session = Active(tabID: start.tabID, source: pane,
                             payload: .tab(id: start.tabID.rawValue, sourceStripID: start.stripID),
                             ghost: ghost, point: start.screenPoint)
        session.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        active = session
        update(start.screenPoint)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDragged:
            update(NSEvent.mouseLocation)
            return nil
        case .leftMouseUp:
            update(NSEvent.mouseLocation)
            finish(commit: true)
            return nil
        case .keyDown where event.keyCode == 53:
            finish(commit: false)
            return nil
        default:
            return event
        }
    }

    // MARK: Hit testing

    private func update(_ point: CGPoint) {
        guard var session = active else { return }
        session.point = point
        session.ghost.move(to: point)
        let target = hitTest(point, session: session)
        clearFeedback(previous: session.target, next: target)
        session.target = target
        active = session
    }

    private func hitTest(_ point: CGPoint, session: Active) -> Target {
        let byWindow = Dictionary(uniqueKeysWithValues: services.windows.controllers.compactMap { c in c.window.map { (ObjectIdentifier($0), c) } })
        guard let controller = NSApp.orderedWindows.lazy.compactMap({ window -> WindowController? in
            guard window.isVisible, window.frame.contains(point) else { return nil }
            return byWindow[ObjectIdentifier(window)]
        }).first, let window = controller.window else { return .outside }
        for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
            if let proposal = pane.view.stripView.dropHitTest(screenPoint: point, payload: session.payload) {
                return .strip(pane, proposal)
            }
        }
        let windowPoint = window.convertPoint(fromScreen: point)
        if let layout = controller.content?.layoutView,
           layout.updateTabDrag(LayoutTabID(session.tabID.rawValue), locationInWindow: windowPoint) != nil {
            return .layout(controller)
        }
        if controller.sidebar.container.sidebarView.tabDragUpdate(screenPoint: point, sourceMachine: .local) != nil {
            return .sidebar(controller)
        }
        return .none
    }

    private func clearFeedback(previous: Target, next: Target) {
        switch (previous, next) {
        case (.strip(let old, _), .strip(let new, _)) where old === new: return
        case (.layout(let old), .layout(let new)) where old === new: return
        case (.sidebar(let old), .sidebar(let new)) where old === new: return
        case (.strip(let old, _), _): old.view.stripView.dropExited()
        case (.layout(let old), _): old.content?.layoutView.cancelTabDrag()
        case (.sidebar(let old), _): old.sidebar.container.sidebarView.tabDragExited()
        default: break
        }
    }

    // MARK: Commit

    private func finish(commit: Bool) {
        guard let session = active else { return }
        active = nil
        if let monitor = session.monitor { NSEvent.removeMonitor(monitor) }
        session.ghost.close()
        let tabID = session.tabID
        let restore: @MainActor (Bool) -> Void = { [weak source = session.source] _ in
            source?.view.stripView.restoreDetachedTab(tabID)
            source?.resyncStrip()
        }
        guard commit, let (tab, _) = services.locateTab(tabID.rawValue) else {
            clearFeedback(previous: session.target, next: .none)
            restore(false)
            return
        }
        switch session.target {
        case .strip(let pane, let proposal):
            pane.view.stripView.dropEnded(committed: proposal)
            guard case .strip(_, let index, _) = proposal.kind else { return restore(false) }
            TabMoves.move(tab, to: pane.pane, index: index, services: services) { ok in if !ok { restore(false) } }
        case .layout(let controller):
            guard let window = controller.window, let layout = controller.content?.layoutView else { return restore(false) }
            let dropped = layout.endTabDrag(LayoutTabID(tabID.rawValue), locationInWindow: window.convertPoint(fromScreen: session.point))
            if dropped == nil { restore(false) }
        case .sidebar(let controller):
            commitSidebar(controller.sidebar.container.sidebarView.tabDragEnded(), tab: tab, window: controller, restore: restore)
        case .outside:
            let point = session.point
            Task {
                guard let key = await TabMoves.toNewWorkspace(tab, services: services) else { return restore(false) }
                let window = services.windows.open(record: nil, workspaceID: key.rawValue)
                window.window?.setFrameTopLeftPoint(point)
            }
        case .none:
            restore(false)
        }
    }

    private func commitSidebar(_ drop: SidebarTabDrop?, tab: TabModel, window: WindowController,
                               restore: @escaping @MainActor (Bool) -> Void) {
        switch drop {
        case .intoWorkspace(let id):
            guard let workspace = services.workspace(id: id.rawValue) else { return restore(false) }
            TabMoves.toWorkspace(tab, workspace: workspace, services: services) { ok in if !ok { restore(false) } }
        case .newWorkspace, .intoGroup:
            Task {
                guard let key = await TabMoves.toNewWorkspace(tab, services: services) else { return restore(false) }
                services.windows.show(workspaceID: key.rawValue, in: window.state)
            }
        case nil:
            restore(false)
        }
    }
}
