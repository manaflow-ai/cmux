import AppKit
import CmuxNextAgentCursor
import CmuxNextAgentCursorVisibility
import CmuxNextLayout
import Observation

/// The live agent cursor visibility: resolves a target tab against the
/// current models (`AgentCursorSnapshotBuilder` + the pure resolver), hands
/// each workspace content's cursor stack its `AgentCursorTargetResolving`,
/// and tells `onChange` when a tracked target's visibility changes between
/// input events (a column scrolls, a window minimizes, a workspace or tab
/// switches).
///
/// No polling and no timers: without an `onChange` consumer, or while no
/// target is tracked, it observes nothing; otherwise it re-resolves only on
/// layout overlay syncs, window notifications, Space changes and window
/// state changes.
final class AgentCursorVisibilitySource {
    private let builder: AgentCursorSnapshotBuilder
    private weak var services: AppServices?
    /// Last result per tracked target.
    private var tracked: [String: AgentCursorVisibility] = [:]
    private var observers: [any NSObjectProtocol] = []
    private var stateObservation: Task<Void, Never>?
    /// Overlay sync observations of the layout roots this source watches.
    private var hookedRoots: [ObjectIdentifier: LayoutRootHook] = [:]
    /// A tracked target's visibility changed; its overlay model re-renders.
    var onChange: ((String, AgentCursorVisibility) -> Void)?

    private struct LayoutRootHook {
        weak var root: LayoutRootView?
        let observation: LayoutOverlaySyncObservation
    }

    init(services: AppServices) {
        self.services = services
        builder = AgentCursorSnapshotBuilder(services: services)
    }

    /// Resolves `target` now. With an `onChange` consumer, also tracks it
    /// until `untrack`; without one nothing is observed (0 idle work).
    func resolve(_ target: String) -> AgentCursorVisibility {
        let result = AgentCursorVisibilityResolver.resolve(target: target, in: builder.snapshot(forTarget: target))
        guard onChange != nil else { return result }
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

    /// The resolver of one workspace content's cursor stack: it draws only
    /// while that content is the one its window shows (a parked content's
    /// plane is off screen).
    func resolver(for content: WorkspaceContentController) -> any AgentCursorTargetResolving {
        AgentCursorContentResolver(content: content, source: self)
    }

    /// The window that shows `content` now, if any.
    func windowID(showing content: WorkspaceContentController) -> String? {
        services?.windows.controllers.first { $0.content === content }?.state.id
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
        for hook in hookedRoots.values { hook.observation.cancel() }
        hookedRoots.removeAll()
    }

    /// Subscribes to the overlay sync of every window's shown layout root
    /// (a newly shown workspace brings a new root).
    private func hookLayoutRoots() {
        guard !tracked.isEmpty else { return }
        hookedRoots = hookedRoots.filter { $0.value.root != nil }
        for controller in services?.windows.controllers ?? [] {
            guard let root = controller.content?.layoutView, hookedRoots[ObjectIdentifier(root)] == nil else { continue }
            let observation = root.observeOverlaySync { [weak self] in self?.reresolve() }
            hookedRoots[ObjectIdentifier(root)] = LayoutRootHook(root: root, observation: observation)
        }
    }
}

/// One workspace content's `AgentCursorTargetResolving`: resolves through
/// the shared source and keeps only what this content's plane draws.
final class AgentCursorContentResolver: AgentCursorTargetResolving {
    private weak var content: WorkspaceContentController?
    private weak var source: AgentCursorVisibilitySource?

    init(content: WorkspaceContentController, source: AgentCursorVisibilitySource) {
        self.content = content
        self.source = source
    }

    func placement(forTarget targetID: String) -> AgentCursorPlacement {
        guard let source, let content, let window = source.windowID(showing: content) else { return .elsewhere }
        return source.resolve(targetID).placement(forWindow: window, overlay: content.layoutView.bounds)
    }
}
