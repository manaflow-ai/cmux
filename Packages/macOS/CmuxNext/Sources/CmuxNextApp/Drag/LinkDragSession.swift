import AppKit
import CmuxNextBridge
import CmuxNextLayout
import CmuxNextPages
import CmuxNextCompat
import CmuxNextTabs

/// A link dragged out of a chat bubble into the layout (Lawrence 2026-10-20: "drag a link, like a
/// PR URL, to the right side or anywhere and make a split").
///
/// The chat hands the press over once it moves past the slop (``begin(_:screenPoint:)``); from
/// then this session tracks the mouse itself with a local event monitor, like ``TabDragSession``,
/// so the drag crosses pages drawn in child windows. Over a window's layout it asks the layout for
/// the same drop zone a dragged tab gets (`LayoutRootView.updateTabDrag`, so the preview, its
/// label and the split dwell are the tab drag's) and the release opens the link there
/// (``LinkOpener/drop(_:plan:in:)``): a pane's center adds a tab, an edge makes a split. A release
/// anywhere else, Escape, or the app going inactive ends it with nothing opened.
@MainActor
final class LinkDragSession {
    /// The layout's drag key for a link (it names no tab; a link drag never emits a tab drop).
    static let dragKey = LayoutTabID("link-drag")

    /// The app's services (they own this session and outlive it).
    private weak var services: AppServices?
    private var drag: Drag?

    private final class Drag {
        let item: LinkDragItem
        let ghost: LinkDragGhost
        var monitor: Any?
        var resign: MainActorObservation?
        /// The window whose layout shows the preview now, and the plan a release there runs.
        weak var window: WindowController?
        var plan: LinkDropPlan?
        init(item: LinkDragItem, ghost: LinkDragGhost) {
            self.item = item
            self.ghost = ghost
        }
    }

    init(services: AppServices) {
        self.services = services
    }

    var isDragging: Bool { drag != nil }

    /// Starts dragging `url` from `screenPoint`; false (nothing starts) for a link that does not
    /// drag (``LinkDragItem``) or while another drag runs, so the chat selects text instead.
    func begin(_ url: URL, screenPoint: CGPoint) -> Bool {
        guard let services, drag == nil, !services.dragSession.isDragging,
              let item = LinkDragItem(url, browserEnabled: LinkRouter.shared.routing().browserEnabled) else { return false }
        let drag = Drag(item: item, ghost: LinkDragGhost(title: item.title))
        drag.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        drag.resign = MainActorObservation(NSApplication.didResignActiveNotification) { [weak self] in
            self?.finish(commit: false)
        }
        self.drag = drag
        drag.ghost.show(at: screenPoint)
        update(screenPoint)
        return true
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDragged:
            update(TabDragSession.screenPoint(of: event))
            return nil
        case .leftMouseUp:
            update(TabDragSession.screenPoint(of: event))
            finish(commit: true)
            return nil
        case .leftMouseDown:
            // A lost mouse-up (another tracking loop ate it): end with nothing opened.
            finish(commit: false)
            return event
        case .keyDown where event.keyCode == 53:
            finish(commit: false)
            return nil
        default:
            return event
        }
    }

    /// The app window under `screenPoint` (a page's child window counts as its parent), below
    /// the ghost.
    private func window(at screenPoint: CGPoint, below ghost: NSWindow) -> WindowController? {
        guard let services else { return nil }
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: ghost.windowNumber)
        var window = NSApp.window(withWindowNumber: number)
        while let child = window, !services.windows.controllers.contains(where: { $0.window === child }), let parent = child.parent {
            window = parent
        }
        return services.windows.controllers.first { $0.window === window && window != nil }
    }

    private func update(_ screenPoint: CGPoint) {
        guard let drag else { return }
        drag.ghost.move(to: screenPoint)
        let controller = window(at: screenPoint, below: drag.ghost.panel)
        if let old = drag.window, old !== controller { old.content?.layoutView.cancelTabDrag() }
        drag.window = controller
        drag.plan = nil
        guard let content = controller?.content, let nsWindow = content.layoutView.window else { return }
        let layout = content.layoutView
        let windowPoint = nsWindow.convertPoint(fromScreen: screenPoint)
        guard layout.bounds.contains(layout.convert(windowPoint, from: nil)) else { return layout.cancelTabDrag() }
        guard let target = layout.updateTabDrag(Self.dragKey, locationInWindow: windowPoint,
                                                edgeDwell: DragTunables.splitDwell.value) else { return }
        let plan = LinkDropPlan(target) { content.panes[$0]?.stripModel.showsNewTabButton == true }
        if plan == nil { layout.hideTabDragHighlight() }
        drag.plan = plan
    }

    private func finish(commit: Bool) {
        guard let drag else { return }
        self.drag = nil
        if let monitor = drag.monitor { NSEvent.removeMonitor(monitor) }
        drag.resign = nil
        drag.ghost.close()
        let content = drag.window?.content
        content?.layoutView.cancelTabDrag()
        guard commit, let plan = drag.plan, let content else { return }
        services?.linkOpener.drop(drag.item, plan: plan, in: content)
    }
}
