import AppKit
import CmuxNextBridge
import CmuxNextInput
import CmuxNextLayout
import CmuxNextPages
import CmuxNextCompat
import CmuxNextTabs
import CmuxNextWakeups

/// A link dragged out of a chat bubble into the layout (Lawrence 2026-10-20: "drag a link, like a
/// PR URL, to the right side or anywhere and make a split").
///
/// The chat hands the press over once it moves past the slop (``begin(_:screenPoint:)``); from
/// then this session tracks the mouse itself with an input tap intercept that lives for the drag,
/// like ``TabDragSession``, so the drag crosses pages drawn in child windows. Over a window's
/// layout it asks the layout for the same drop zone a dragged tab gets (`LayoutRootView.updateTabDrag`,
/// so the preview, its label and the split dwell are the tab drag's) and the release opens the link
/// there (``LinkOpener/drop(_:plan:in:)``): a pane's center adds a tab, an edge makes a split. A
/// release anywhere else, Escape, a press after a lost release, or the app going inactive ends it
/// with nothing opened.
///
/// With `motion.renderServer` on the pill (``LinkDragGhost``) shows in the source window's overlay while
/// the pointer is over that window and the window shows the pill in front, as the tab drag ghost does
/// (p03-rendering-035): a pointer move there moves one view, with no window call. The window a release
/// opens the link in is the screen's window under the pointer either way (another app's window or a cmux
/// window that is no layout window, Settings for one, takes the drop from every window behind it).
@MainActor
final class LinkDragSession {
    /// The layout's drag key for a link (it names no tab; a link drag never emits a tab drop).
    static let dragKey = LayoutTabID("link-drag")

    /// The app's services (they own this session and outlive it).
    private weak var services: AppServices?
    /// `motion.renderServer`, read once per drag (tests inject it).
    private let rendersOnServer: @MainActor () -> Bool
    private var drag: Drag?

    private final class Drag {
        let item: LinkDragItem
        let ghost: LinkDragGhost
        /// The drag's input tap intercept; cancelled when the drag ends.
        var input: InputSubscription?
        /// The app's resign-active notice ends the drag (``AppEvents``: one observer for the app).
        var resign: EventSubscription?
        /// The window the drag started in (its overlay holds the pill there).
        let sourceID: String?
        /// The window whose layout shows the preview now, and the plan a release there runs.
        weak var window: WindowController?
        var plan: LinkDropPlan?
        init(item: LinkDragItem, ghost: LinkDragGhost, sourceID: String?) {
            self.item = item
            self.ghost = ghost
            self.sourceID = sourceID
        }
    }

    init(services: AppServices, rendersOnServer: @escaping @MainActor () -> Bool = { LayoutTunables.motionRenderServer.value }) {
        self.services = services
        self.rendersOnServer = rendersOnServer
    }

    var isDragging: Bool { drag != nil }
    /// The running drag's pill (tests, diagnostics).
    var ghost: LinkDragGhost? { drag?.ghost }
    /// The window whose layout shows the drop preview now (tests, diagnostics).
    var target: WindowController? { drag?.window }

    /// Starts dragging `url` from `screenPoint`; false (nothing starts) for a link that does not
    /// drag (``LinkDragItem``) or while another drag runs, so the chat selects text instead.
    func begin(_ url: URL, screenPoint: CGPoint) -> Bool {
        guard let services, drag == nil, !services.dragSession.isDragging,
              let item = LinkDragItem(url, browserEnabled: LinkRouter.shared.routing().browserEnabled) else { return false }
        // The press is in a chat of the window on screen under it: the drag's source window.
        let source = window(at: screenPoint, below: 0)
        let ghost = LinkDragGhost(title: item.title, sourceWindow: source?.window, rendersOnServer: rendersOnServer())
        let drag = Drag(item: item, ghost: ghost, sourceID: source?.state.id)
        drag.input = services.inputTap.subscribe(class: TabDragSession.dragInput, phase: .intercept(order: .dragSession)) { [weak self] event in
            self?.handle(event) ?? .pass
        }
        drag.resign = services.appEvents.subscribe(NSApplication.didResignActiveNotification, owner: "LinkDragSession.resign") { [weak self] in
            self?.finish(commit: false)
        }
        self.drag = drag
        update(screenPoint)
        return true
    }

    private func handle(_ event: NSEvent) -> InputEventTap.InterceptResult {
        switch event.type {
        case .leftMouseDragged:
            update(TabDragSession.screenPoint(of: event))
            return .consume
        case .leftMouseUp:
            update(TabDragSession.screenPoint(of: event))
            finish(commit: true)
            return .consume
        case .leftMouseDown:
            // A lost mouse-up (a nested tracking loop dequeued it): end with nothing opened; the
            // press goes on to what it hit.
            finish(commit: false)
            return .pass
        case .keyDown where event.keyCode == 53:
            finish(commit: false)
            return .consume
        default:
            return .pass
        }
    }

    /// The app window on screen under `screenPoint` (a page's child window counts as its parent), below the
    /// window numbered `below` (0: the topmost). The screen's order of every app's windows: another app's window,
    /// or a cmux window that is no layout window, over the pointer means no window.
    private func window(at screenPoint: CGPoint, below: Int) -> WindowController? {
        guard let services else { return nil }
        let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: below)
        var window = NSApp.window(withWindowNumber: number)
        while let child = window, !services.windows.controllers.contains(where: { $0.window === child }), let parent = child.parent {
            window = parent
        }
        return services.windows.controllers.first { $0.window === window && window != nil }
    }

    /// One pointer event of the drag. The window under the pointer is the screen's (``window(at:below:)``, below
    /// the pill's panel while it shows). On the render server, while that is the source window, the tab drag's
    /// hold rule (``TabDragSession/holds(_:at:in:)``, one walk of the app's windows) decides whether the source
    /// window's overlay holds the pill.
    private func update(_ screenPoint: CGPoint) {
        guard let drag else { return }
        let panel = drag.ghost.panel
        let controller = window(at: screenPoint, below: panel.isVisible ? panel.windowNumber : 0)
        var holds: ((CGRect) -> Bool)?
        if drag.ghost.rendersOnServer, let id = drag.sourceID, controller?.state.id == id, let tabDrags = services?.dragSession {
            holds = TabDragSession.holds(id, at: screenPoint, in: tabDrags.windowOrder(source: drag.ghost.sourceWindow, ghost: panel))
        }
        drag.ghost.move(to: screenPoint, holds: holds)
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
        drag.input?.cancel()
        drag.input = nil
        drag.resign?.cancel()
        drag.resign = nil
        drag.ghost.close()
        let content = drag.window?.content
        content?.layoutView.cancelTabDrag()
        guard commit, let plan = drag.plan, let content else { return }
        services?.linkOpener.drop(drag.item, plan: plan, in: content)
    }
}
