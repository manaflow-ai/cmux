import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSidebar
import CmuxNextTabs

/// A screen tab dragged out of the screen bar. Reordering inside the bar is
/// the strip's own drag; once the pointer leaves the bar the strip hands the
/// drag here. Released over a workspace row in any window's sidebar, the
/// screen moves into that workspace; over a sidebar gap, into a new
/// workspace; outside every window, into a new window (Chrome's tear-off).
/// Anywhere else, or on Escape, it returns to its slot. Event-driven: a
/// local event monitor for the drag's mouse events, no timers.
@MainActor
final class ScreenDragSession {
    private let services: AppServices
    private let screen: ScreenModel
    private let daemon: DaemonService
    private let source: WorkspaceModel
    private weak var strip: TabStripView?
    private let tabID: StripTabID
    private var monitor: Any?
    private var targets: [ObjectIdentifier: SidebarTabDropTarget] = [:]
    private var lastTarget: SidebarTabDropTarget?
    /// Called once the drag ended (the bar drops its reference).
    var onEnd: (() -> Void)?

    init(services: AppServices, screen: ScreenModel, daemon: DaemonService, source: WorkspaceModel, strip: TabStripView, tabID: StripTabID) {
        self.services = services
        self.screen = screen
        self.daemon = daemon
        self.source = source
        self.strip = strip
        self.tabID = tabID
    }

    func begin() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDragged:
                self.track(Self.screenPoint(of: event))
                return nil
            case .leftMouseUp:
                self.finish(at: Self.screenPoint(of: event))
                return nil
            case .keyDown where event.keyCode == 53:
                self.finish(at: nil)
                return nil
            default:
                return event
            }
        }
    }

    private static func screenPoint(of event: NSEvent) -> CGPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    private func window(at point: CGPoint) -> WindowController? {
        let controllers = services.windows.controllers
        for window in NSApp.orderedWindows where window.isVisible && !window.isMiniaturized && window.frame.contains(point) {
            if let controller = controllers.first(where: { $0.window === window }) { return controller }
        }
        return nil
    }

    private func target(for controller: WindowController) -> SidebarTabDropTarget {
        let key = ObjectIdentifier(controller)
        if let target = targets[key] { return target }
        let target = SidebarTabDropTarget(bridge: controller.sidebar)
        target.sourceMachine = MachineID(daemon.machineID)
        targets[key] = target
        return target
    }

    /// Lights the sidebar row or gap under the pointer.
    @discardableResult
    private func track(_ point: CGPoint) -> (WindowController, SidebarTabDropHit)? {
        let controller = window(at: point)
        let current = controller.map(target(for:))
        if let lastTarget, lastTarget !== current { lastTarget.dropExited() }
        lastTarget = current
        guard let controller, let hit = current?.hit(screenPoint: point) else { return nil }
        return (controller, hit)
    }

    private func finish(at point: CGPoint?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let hit = point.flatMap { track($0) }
        for target in targets.values { target.dropEnded(committed: nil) }
        strip?.restoreDetachedTab(tabID)
        defer { onEnd?() }
        guard let point else { return }
        if let (controller, hit) = hit {
            switch hit.drop {
            case .intoWorkspace(let id):
                guard id.rawValue != source.id, let target = services.workspace(id: id.rawValue) else { return }
                ScreenCommands.move(screen, toWorkspace: target, daemon: daemon)
            case .newWorkspace, .intoGroup:
                services.windows.didActivate(controller)
                ScreenCommands.moveToNewWorkspace(screen, daemon: daemon, services: services, newWindow: false)
            }
        } else if window(at: point) == nil {
            ScreenCommands.moveToNewWorkspace(screen, daemon: daemon, services: services, newWindow: true)
        }
    }
}
