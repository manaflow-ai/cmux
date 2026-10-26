import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextInput
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextWakeups

/// A screen tab dragged out of the screen bar. Reordering inside the bar is
/// the strip's own drag; once the pointer leaves the bar the strip hands the
/// drag here. Released over a workspace row in any window's sidebar, the
/// screen moves into that workspace; over a sidebar gap, into a new
/// workspace; outside every window, into a new window (tear-off).
/// Anywhere else, on Escape, at a press after a lost release, or when the app
/// goes inactive, it returns to its slot. Event-driven: an input tap intercept
/// for the drag's events and an app-resign observer, alive for the drag only,
/// no timers.
@MainActor
final class ScreenDragSession {
    private let services: AppServices
    private let screen: ScreenModel
    private let daemon: DaemonService
    private let source: WorkspaceModel
    private weak var strip: TabStripView?
    private let tabID: StripTabID
    /// The drag's input tap intercept; cancelled when the drag ends (and when the session goes).
    private var input: InputSubscription?
    /// Ends the drag when the app goes inactive (a release in another app never reaches the tap).
    private var resign: EventSubscription?
    /// The app's fan-out of app-wide notices (`AppServices.appEvents`; tests pass their own).
    private let appEvents: AppEvents
    private var targets: [ObjectIdentifier: SidebarTabDropTarget] = [:]
    private var lastTarget: SidebarTabDropTarget?
    /// Called once the drag ended (the bar drops its reference).
    var onEnd: (() -> Void)?

    init(services: AppServices, screen: ScreenModel, daemon: DaemonService, source: WorkspaceModel, strip: TabStripView, tabID: StripTabID,
         appEvents: AppEvents) {
        self.services = services
        self.appEvents = appEvents
        self.screen = screen
        self.daemon = daemon
        self.source = source
        self.strip = strip
        self.tabID = tabID
    }

    func begin() {
        input = services.inputTap.subscribe(class: TabDragSession.dragInput, phase: .intercept(order: .dragSession)) { [weak self] event in
            self?.handle(event) ?? .pass
        }
        resign = appEvents.subscribe(NSApplication.didResignActiveNotification, owner: "ScreenDragSession") { [weak self] in // raw-observer-allow: this is the AppEvents fan-out (one app observer), not a raw one
            self?.finish(at: nil)
        }
    }

    private func handle(_ event: NSEvent) -> InputEventTap.InterceptResult {
        switch event.type {
        case .leftMouseDragged:
            track(Self.screenPoint(of: event))
            return .consume
        case .leftMouseUp:
            finish(at: Self.screenPoint(of: event))
            return .consume
        case .leftMouseDown:
            // A lost mouse-up (a nested tracking loop dequeued it): back to the slot, as the tab
            // drag does; the press goes on to what it hit.
            finish(at: nil)
            return .pass
        case .keyDown where event.keyCode == 53:
            finish(at: nil)
            return .consume
        default:
            return .pass
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
        guard let input else { return }
        input.cancel()
        self.input = nil
        resign?.cancel()
        resign = nil
        let hit = point.flatMap { track($0) }
        for target in targets.values { target.dropEnded(committed: nil) }
        strip?.restoreDetachedTab(tabID)
        defer { onEnd?() }
        guard let point else { return }
        if let (controller, hit) = hit {
            switch hit.drop {
            case .intoWorkspace(let id), .beforeTab(let id, _):
                guard id.rawValue != source.id, let target = services.workspace(id: id.rawValue) else { return }
                ScreenCommands.move(screen, toWorkspace: target, daemon: daemon, services: services)
            case .newWorkspace, .intoGroup:
                services.windows.didActivate(controller)
                ScreenCommands.moveToNewWorkspace(screen, daemon: daemon, services: services, newWindow: false)
            }
        } else if window(at: point) == nil {
            ScreenCommands.moveToNewWorkspace(screen, daemon: daemon, services: services, newWindow: true)
        }
    }
}
