import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextSidebar

/// The Chief dragged out of Home's conversation list into a window's sidebar (Leo 2026-10-21: "you can just
/// DRAG IN a Chief and have it displayed and moved around, like a special workspace"). Off by default: the
/// drop adds the Chief item (`sidebar.item.add {chief}`, the top rows, as Add to Sidebar does), which then
/// moves like any row (into a group, Pinned, another section) and comes off by a drag out or Remove from
/// Sidebar.
///
/// Home hands the press over once its row drag leaves the list (``begin(screenPoint:)``); from then this
/// session tracks the mouse itself with a local event monitor, like ``LinkDragSession``. Over a window's
/// sidebar the list shows the drop outline; a release there adds the item. A release anywhere else, Escape,
/// or the app going inactive ends it with nothing added.
@MainActor
final class ChiefDragSession {
    /// The drag in flight, which keeps its session until it ends (`finish`): one at a time.
    private static var active: ChiefDragSession?
    /// The app's services (they outlive the drag).
    private weak var services: AppServices?
    private var drag: Drag?

    private final class Drag {
        let ghost: LinkDragGhost
        var monitor: Any?
        var resign: (any NSObjectProtocol)?
        /// The window whose sidebar takes the drop now.
        weak var window: WindowController?
        init(ghost: LinkDragGhost) { self.ghost = ghost }
    }

    private init(services: AppServices) {
        self.services = services
    }

    /// Starts dragging the Chief from `screenPoint`; false (nothing starts) while another drag runs, so
    /// Home's own drag goes on.
    static func begin(services: AppServices, screenPoint: CGPoint) -> Bool {
        guard active == nil, !services.dragSession.isDragging, !services.linkDrags.isDragging else { return false }
        let session = ChiefDragSession(services: services)
        active = session
        session.start(at: screenPoint)
        return true
    }

    private func start(at screenPoint: CGPoint) {
        let drag = Drag(ghost: LinkDragGhost(title: SidebarItemInfo.fallback(for: .builtIn(.chief)).title))
        drag.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        drag.resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(commit: false) } // main-proof: observer on queue: .main
        }
        self.drag = drag
        drag.ghost.show(at: screenPoint)
        update(screenPoint)
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
            // A lost mouse-up (another tracking loop ate it): end with nothing added.
            finish(commit: false)
            return event
        case .keyDown where event.keyCode == 53:
            finish(commit: false)
            return nil
        default:
            return event
        }
    }

    /// The app window under `screenPoint` (a page's child window counts as its parent), below the ghost.
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
        if let old = drag.window, old !== controller { old.sidebar.container.sidebarView.itemDragExited() }
        // The window's sidebar takes the drop only while the pointer is over it.
        drag.window = controller?.sidebar.container.sidebarView.itemDragUpdate(screenPoint: screenPoint) == true ? controller : nil
    }

    private func finish(commit: Bool) {
        guard let drag else { return }
        self.drag = nil
        if Self.active === self { Self.active = nil }
        if let monitor = drag.monitor { NSEvent.removeMonitor(monitor) }
        if let resign = drag.resign { NotificationCenter.default.removeObserver(resign) }
        drag.ghost.close()
        drag.window?.sidebar.container.sidebarView.itemDragExited()
        guard commit, drag.window != nil, let registry = services?.registry else { return }
        // Already in the sidebar: it stays where it is (a drag there moves it).
        guard !ChiefSidebar.shared.isPlaced else { return }
        _ = registry.perform("sidebar.item.add", invocation: ActionInvocation(arguments: ["item": .string(SidebarBuiltIn.chief.rawValue)], origin: .user))
    }
}
