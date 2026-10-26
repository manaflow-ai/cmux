public import AppKit
public import CmuxNextSidebar
import CmuxNextTabs

/// The Chief dragged out of Home's conversation list into a window's sidebar (Leo 2026-10-21: "you can just
/// DRAG IN a Chief and have it displayed and moved around, like a special workspace"). Off by default: the
/// drop adds the Chief item (`host.drop`, `sidebar.item.add {chief}`, the top rows, as Add to Sidebar does),
/// which then moves like any row and comes off by Remove from Sidebar.
///
/// Home hands the press over once its row drag leaves the list (``begin(at:)``); from then the drag tracks the
/// mouse itself with one local event monitor, like the App's link drag. Over a window's sidebar the list shows
/// the drop outline; a release there adds the item. A release anywhere else, Escape, a lost release (the next
/// press) or the app going inactive (its `applicationDeactivated` event, the same monitor) ends it with nothing
/// added. The owner (Home's page) keeps one instance; the monitor holds it until the drag ends, so an owner gone
/// mid-drag (its page closed) leaves no monitor or ghost behind.
@MainActor
public final class ChiefDragIn {
    /// What the drag reaches in the App: the sidebar of the app window under a screen point (below the ghost's
    /// window number), whether another drag runs, and the drop.
    public struct Host {
        public var sidebar: (_ screenPoint: CGPoint, _ belowWindowNumber: Int) -> SidebarView?
        public var isBusy: () -> Bool
        public var drop: () -> Void

        public init(sidebar: @escaping (CGPoint, Int) -> SidebarView?, isBusy: @escaping () -> Bool, drop: @escaping () -> Void) {
            self.sidebar = sidebar
            self.isBusy = isBusy
            self.drop = drop
        }
    }

    private final class Drag {
        let ghost: LinkDragGhost
        var monitor: Any?
        /// The sidebar that takes the drop now.
        weak var sidebar: SidebarView?
        init(ghost: LinkDragGhost) { self.ghost = ghost }
    }

    private let host: Host
    private let chief: ChiefSidebar
    private var drag: Drag?

    public init(host: Host, chief: ChiefSidebar = .shared) {
        self.host = host
        self.chief = chief
    }

    public var isDragging: Bool { drag != nil }

    /// Starts dragging the Chief from `screenPoint`; false (nothing starts) while a drag runs, so Home's own drag goes on.
    public func begin(at screenPoint: CGPoint) -> Bool {
        guard drag == nil, !host.isBusy() else { return false }
        let drag = Drag(ghost: LinkDragGhost(title: SidebarItemInfo.fallback(for: .builtIn(.chief)).title))
        // Strong until `finish` removes the monitor: the drag keeps this alive however its owner goes.
        drag.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .leftMouseDown, .keyDown, .appKitDefined]) {
            event in self.handle(event)
        }
        self.drag = drag
        drag.ghost.show(at: screenPoint)
        update(screenPoint)
        return true
    }

    /// One event of the app while the drag runs (the monitor's); nil swallows it.
    func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDragged:
            update(Self.screenPoint(of: event))
            return nil
        case .leftMouseUp:
            update(Self.screenPoint(of: event))
            finish(commit: true)
            return nil
        case .leftMouseDown:
            // A lost mouse-up (another tracking loop ate it): end with nothing added.
            finish(commit: false)
            return event
        case .keyDown where event.keyCode == 53:
            finish(commit: false)
            return nil
        case .appKitDefined where event.subtype == .applicationDeactivated:
            finish(commit: false)
            return event
        default:
            return event
        }
    }

    private static func screenPoint(of event: NSEvent) -> CGPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    private func update(_ screenPoint: CGPoint) {
        guard let drag else { return }
        drag.ghost.move(to: screenPoint)
        let sidebar = host.sidebar(screenPoint, drag.ghost.panel.windowNumber)
        if let old = drag.sidebar, old !== sidebar { old.itemDragExited() }
        // The sidebar takes the drop only while the pointer is over it.
        drag.sidebar = sidebar?.itemDragUpdate(screenPoint: screenPoint) == true ? sidebar : nil
    }

    private func finish(commit: Bool) {
        guard let drag else { return }
        self.drag = nil
        if let monitor = drag.monitor { NSEvent.removeMonitor(monitor) }
        drag.ghost.close()
        drag.sidebar?.itemDragExited()
        // Already in the sidebar: it stays where it is (a drag there moves it).
        guard commit, drag.sidebar != nil, !chief.isPlaced else { return }
        host.drop()
    }
}
