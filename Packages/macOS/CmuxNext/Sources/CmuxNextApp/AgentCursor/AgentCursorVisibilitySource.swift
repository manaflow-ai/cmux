import AppKit
import CmuxNextAgentCursor
import CmuxNextAgentCursorVisibility
import CmuxNextLayout
import Observation

/// The live agent cursor visibility: resolves a target tab against the
/// current models (`AgentCursorSnapshotBuilder` + the pure resolver), hands
/// each window's overlay model its `AgentCursorTargetResolving`, and tells
/// `onChange` when a tracked target's visibility changes between input
/// events (a column scrolls, a window minimizes, a workspace or tab switches).
///
/// No polling and no timers: while no target is tracked it observes nothing;
/// while some are, it re-resolves only on layout overlay syncs, window
/// notifications, Space changes and window state changes.
final class AgentCursorVisibilitySource {
    private let builder: AgentCursorSnapshotBuilder
    private weak var services: AppServices?
    /// Last result per tracked target.
    private var tracked: [String: AgentCursorVisibility] = [:]
    private var observers: [any NSObjectProtocol] = []
    private var stateObservation: Task<Void, Never>?
    /// Layout roots whose overlay sync this source subscribed to.
    private var hookedRoots: [ObjectIdentifier: LayoutRootHook] = [:]
    /// A tracked target's visibility changed; its overlay model re-renders.
    var onChange: ((String, AgentCursorVisibility) -> Void)?

    private struct LayoutRootHook { weak var root: LayoutRootView? }

    init(services: AppServices) {
        self.services = services
        builder = AgentCursorSnapshotBuilder(services: services)
    }

    /// Resolves `target` now and tracks it until `untrack`.
    func resolve(_ target: String) -> AgentCursorVisibility {
        let result = AgentCursorVisibilityResolver.resolve(target: target, in: builder.snapshot(forTarget: target))
        let wasIdle = tracked.isEmpty
        tracked[target] = result
        if wasIdle { startObserving() }
        return result
    }

    /// Stops tracking `target` (its lease ended). The last target stops every observer.
    func untrack(_ target: String) {
        guard tracked.removeValue(forKey: target) != nil, tracked.isEmpty else { return }
        stopObserving()
    }

    /// The resolver one window's overlay model asks.
    func resolver(forWindow windowID: String) -> any AgentCursorTargetResolving {
        AgentCursorWindowResolver(windowID: windowID, source: self)
    }

    /// The overlay bounds of `windowID` (its shown layout root).
    func overlayBounds(ofWindow windowID: String) -> CGRect {
        services?.windows.controller(for: windowID)?.content?.layoutView.bounds ?? .zero
    }

    // MARK: Invalidation

    private func reresolve() {
        for (target, last) in tracked {
            let result = AgentCursorVisibilityResolver.resolve(target: target, in: builder.snapshot(forTarget: target))
            guard result != last else { continue }
            tracked[target] = result
            onChange?(target, result)
        }
        hookLayoutRoots()
    }

    private func startObserving() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didResizeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard note.object is ShellWindow else { return }
                Task { @MainActor in self?.reresolve() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reresolve() } })
        guard let windows = services?.windows else { return }
        stateObservation = Task { [weak self] in
            // Shown workspace, tab selection and sidebar of every window.
            for await _ in Observations({ () -> [String] in
                windows.controllers.map { controller in
                    let state = controller.state
                    return "\(state.workspaceID ?? "-"):\(state.sidebarHidden):\(String(describing: state.selection))"
                }
            }) {
                self?.reresolve()
            }
        }
        hookLayoutRoots()
    }

    private func stopObserving() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            workspaceCenter.removeObserver(observer)
        }
        observers.removeAll()
        stateObservation?.cancel()
        stateObservation = nil
        for hook in hookedRoots.values { hook.root?.onOverlaySync = nil }
        hookedRoots.removeAll()
    }

    /// Subscribes to the overlay sync of every window's shown layout root
    /// (a newly shown workspace brings a new root).
    private func hookLayoutRoots() {
        guard !tracked.isEmpty else { return }
        hookedRoots = hookedRoots.filter { $0.value.root != nil }
        for controller in services?.windows.controllers ?? [] {
            guard let root = controller.content?.layoutView, hookedRoots[ObjectIdentifier(root)] == nil else { continue }
            root.onOverlaySync = { [weak self] in self?.reresolve() }
            hookedRoots[ObjectIdentifier(root)] = LayoutRootHook(root: root)
        }
    }
}

/// One window's `AgentCursorTargetResolving`: resolves through the shared
/// source and keeps only what this window draws.
final class AgentCursorWindowResolver: AgentCursorTargetResolving {
    let windowID: String
    private weak var source: AgentCursorVisibilitySource?

    init(windowID: String, source: AgentCursorVisibilitySource) {
        self.windowID = windowID
        self.source = source
    }

    func placement(forTarget targetID: String) -> AgentCursorPlacement {
        guard let source else { return .elsewhere }
        return source.resolve(targetID).placement(forWindow: windowID, overlay: source.overlayBounds(ofWindow: windowID))
    }
}
