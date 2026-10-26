import AppKit
import CmuxNextAgentCursor
import CmuxNextAgentCursorVisibility
import CmuxNextCompat
import CmuxNextLayout
import CmuxNextWakeups
import Observation

/// The live agent cursor visibility: resolves a target tab against the
/// current models (`AgentCursorSnapshotBuilder` + the pure resolver), hands
/// each window's cursor host its `AgentCursorTargetResolving`,
/// and tells `onChange` when a tracked target's visibility changes between
/// input events (a column scrolls, a window minimizes, a workspace or tab
/// switches).
///
/// No polling and no timers: without an `onChange` consumer, or while no
/// target is tracked, it observes nothing; otherwise it re-resolves only on
/// layout overlay syncs, window notifications, Space changes and window
/// state changes. Notices and state changes re-resolve in the automation
/// class (plans/cmux-next/chrome-parity/p06-scheduler.md, task 205).
final class AgentCursorVisibilitySource {
    private let builder: AgentCursorSnapshotBuilder
    private weak var services: AppServices?
    /// Last result per tracked target.
    private var tracked: [String: AgentCursorVisibility] = [:]
    private var spaceSubscription: EventSubscription?
    private var stateObservation: ServiceObservation<[String]>?
    /// A re-resolve is posted and has not run.
    private var reresolveQueued = false
    /// Overlay sync observations of the layout roots this source watches.
    private var hookedRoots: [ObjectIdentifier: LayoutRootHook] = [:]
    /// Window notice subscriptions of the cmux windows this source watches.
    private var hookedWindows: [ObjectIdentifier: WindowHook] = [:]
    /// A tracked target's visibility changed; its overlay model re-renders.
    var onChange: ((String, AgentCursorVisibility) -> Void)?

    private struct LayoutRootHook {
        weak var root: LayoutRootView?
        let observation: LayoutOverlaySyncObservation
    }

    private struct WindowHook {
        weak var window: NSWindow?
        let subscriptions: [EventSubscription]
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

    /// The resolver of one window's cursor host (the window-level overlay
    /// layer): placements in the window's content-view coordinates, flipped.
    func resolver(forWindow windowID: String) -> any AgentCursorTargetResolving {
        AgentCursorWindowResolver(windowID: windowID, source: self)
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

    /// One re-resolve in the automation class for a burst of window and Space notices: the
    /// cursor is an agent's, so its work waits behind the person's input and frames.
    private func scheduleReresolve() {
        guard !reresolveQueued, let services else { return }
        reresolveQueued = true
        services.mainWork.post(.automation, owner: "agent-cursor.visibility") { [weak self] in
            guard let self else { return }
            reresolveQueued = false
            reresolve()
        }
    }

    /// Follows the window state, the Space and every window's shown workspace, tab selection and
    /// sidebar while a target is tracked.
    private func startObserving() {
        guard let services else { return }
        spaceSubscription = services.workspaceEvents.subscribe(
            NSWorkspace.activeSpaceDidChangeNotification, owner: "agent-cursor.visibility") { [weak self] in self?.scheduleReresolve() }
        let windows = services.windows
        stateObservation = ServiceObservation(.automation, owner: "agent-cursor.visibility", on: services.mainWork) { () -> [String] in
            windows.controllers.map { controller in
                let state = controller.state
                return "\(state.workspaceID ?? "-"):\(state.sidebarHidden):\(state.selection.revision)"
            }
        } apply: { [weak self] _ in
            self?.reresolve()
        }
        hookLayoutRoots()
    }

    private func stopObserving() {
        spaceSubscription?.cancel()
        spaceSubscription = nil
        stateObservation?.cancel()
        stateObservation = nil
        for hook in hookedRoots.values { hook.observation.cancel() }
        hookedRoots.removeAll()
        for hook in hookedWindows.values { hook.subscriptions.forEach { $0.cancel() } }
        hookedWindows.removeAll()
    }

    /// Subscribes to the overlay sync of every window's shown layout root
    /// (a newly shown workspace brings a new root), and to each cmux window's
    /// own state notices (a new window brings its own).
    private func hookLayoutRoots() {
        guard !tracked.isEmpty else { return }
        hookedRoots = hookedRoots.filter { $0.value.root != nil }
        hookedWindows = hookedWindows.filter { $0.value.window != nil }
        for controller in services?.windows.controllers ?? [] {
            if let window = controller.window as? ShellWindow, hookedWindows[ObjectIdentifier(window)] == nil {
                hookedWindows[ObjectIdentifier(window)] = WindowHook(window: window, subscriptions: subscribeNotices(of: window))
            }
            guard let root = controller.content?.layoutView, hookedRoots[ObjectIdentifier(root)] == nil else { continue }
            let observation = root.observeOverlaySync { [weak self] in self?.reresolve() }
            hookedRoots[ObjectIdentifier(root)] = LayoutRootHook(root: root, observation: observation)
        }
    }

    /// A cmux window's notices that move or hide what it shows, through the window's one
    /// observer per name (``WindowEvents``).
    private func subscribeNotices(of window: NSWindow) -> [EventSubscription] {
        let events = WindowEvents.of(window), owner = "agent-cursor.visibility"
        let changed: @MainActor () -> Void = { [weak self] in self?.scheduleReresolve() }
        return [
            events.subscribe(NSWindow.didMiniaturizeNotification, owner: owner, changed),
            events.subscribe(NSWindow.didDeminiaturizeNotification, owner: owner, changed),
            events.subscribe(NSWindow.didChangeOcclusionStateNotification, owner: owner, changed),
            events.subscribe(NSWindow.didChangeScreenNotification, owner: owner, changed),
            events.subscribe(NSWindow.didResizeNotification, owner: owner, changed),
        ]
    }
}

/// One window's `AgentCursorTargetResolving` for the window-level cursor
/// host: the resolver's rects as they are (window content view, flipped).
final class AgentCursorWindowResolver: AgentCursorTargetResolving {
    let windowID: String
    private weak var source: AgentCursorVisibilitySource?

    init(windowID: String, source: AgentCursorVisibilitySource) {
        self.windowID = windowID
        self.source = source
    }

    func placement(forTarget targetID: String) -> AgentCursorPlacement {
        source?.resolve(targetID).placement(forWindow: windowID) ?? .elsewhere
    }
}
