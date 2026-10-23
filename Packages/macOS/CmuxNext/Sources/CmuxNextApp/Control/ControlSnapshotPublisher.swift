import AppKit
import CmuxNextControl
import CmuxNextDaemon
import Observation
import os

/// Publishes the control snapshot (architecture.md 5a) after the model
/// settles: at most once per display frame, and only the parts whose reads
/// changed.
///
/// Three parts, each built inside its own Observation tracking, so a change
/// of what one part read republishes that part alone (``Parts``): the
/// topology (every machine's workspaces, O(workspaces + panes)), the
/// settings root, and the Search Tabs facts (the location trail, closing and
/// closed tabs). A window switch moves the trail and the window facts, never
/// a workspace: it costs the trail and O(windows), not every workspace
/// (perf-lead.md cause 6). Every main-actor work queue frame and a window
/// closing republish every part.
///
/// Key and activation changes (not observable) move only the window facts
/// (which window is key, the focus): they republish those, O(windows). When
/// a model publish is held by ``modelChangeInterval`` at that moment, the key
/// change flushes it on the same frame, so the focus a reader without a write
/// barrier gets (`identify`, the current-* queries) always resolves in the
/// workspaces published with it. Readers never touch main-actor state: they
/// get the last published value.
///
/// Open (perf-lead.md row 8): a topology change still maps every workspace
/// through ``ControlWorkspaceInfoCache``, held to one publish per
/// ``modelChangeInterval``; per-workspace invalidation needs the pane app
/// facts (selected tab, page tabs) observable first.
@MainActor
final class ControlSnapshotPublisher {
    /// The parts of the control snapshot, each tracked and republished on its own.
    struct Parts: OptionSet, Sendable {
        let rawValue: UInt8
        /// Every machine's workspaces, the windows and the focus (``topology(_:cache:)``).
        static let topology = Parts(rawValue: 1 << 0)
        /// The settings root.
        static let settings = Parts(rawValue: 1 << 1)
        /// The Search Tabs facts (``TabSearchFactsBuilder``).
        static let tabSearch = Parts(rawValue: 1 << 2)
        /// The window facts alone (``windowInfos(_:cache:)``, ``focus(_:)``), O(windows): what a
        /// key or activation notice moves. Implied by `topology`.
        static let windows = Parts(rawValue: 1 << 3)
        /// The model parts: what a tracked change or a work queue frame republishes.
        static let model: Parts = [.topology, .settings, .tabSearch]
    }

    private let router: ControlRouter
    private unowned let services: AppServices
    private let frames: any ControlFrameSource
    private var isScheduled = false
    /// What the scheduled frame publishes.
    private var pending: Parts = []
    /// A model-change publish waits until then (`modelChanged`); nil publishes on the next frame.
    private var notBefore: ContinuousClock.Instant?
    private var lastPublish = ContinuousClock.now
    /// Model changes (agent status ticks reach hundreds a second) publish at most this often:
    /// a topology publish maps every workspace. A read waiting on a write barrier still publishes at once.
    static let modelChangeInterval: Duration = .milliseconds(100)
    private var isStopped = false
    private var observers: [any NSObjectProtocol] = []
    /// Per-workspace control values kept between publishes (cx-9c8m).
    private let workspaceInfos = ControlWorkspaceInfoCache()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "control.snapshot")

    init(router: ControlRouter, services: AppServices, frames: any ControlFrameSource) {
        self.router = router
        self.services = services
        self.frames = frames
    }

    func start() {
        workspaceInfos.onStale = { [weak self] in self?.modelChanged(.topology) }
        // Read-your-writes for local state: a CLI mutation's effect on focus
        // or selection is in the snapshot before the next request is read.
        router.workQueue.setAfterFrame { [weak self] in self?.publishNow() }
        let center = NotificationCenter.default
        // A window that closes leaves the window list: everything.
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate(.model, notBefore: nil) } // main-proof: observer on queue: .main
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate(.windows, notBefore: nil) } // main-proof: observer on queue: .main
            })
        }
        publishNow()
    }

    func stop() {
        isStopped = true
        router.workQueue.setAfterFrame(nil)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Schedules `parts` on the next frame (coalesced with what is pending); a model part with
    /// `notBefore` waits for the first frame from then on, unless a plain invalidate or a key
    /// change comes first.
    private func invalidate(_ parts: Parts, notBefore new: ContinuousClock.Instant?) {
        if !parts.isDisjoint(with: .model) {
            let modelScheduled = isScheduled && !pending.isDisjoint(with: .model)
            notBefore = new.flatMap { new in modelScheduled ? notBefore.map { min($0, new) } : new }
        }
        pending.formUnion(parts)
        guard !isScheduled, !isStopped else { return }
        isScheduled = true
        frames.scheduleFrame { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            let parts = self.pending
            // A held model publish waits, unless a key change is pending: then both go now, so
            // the published focus resolves in the published workspaces.
            if !parts.contains(.windows), !parts.isDisjoint(with: .model), let wait = self.notBefore,
               ContinuousClock.now < wait, !self.router.snapshots.hasWaiters {
                self.pending = []
                return self.invalidate(parts, notBefore: wait)
            }
            self.publish(parts)
        }
    }

    /// A tracked read of `part` changed. A compat read waiting on the write barrier gets every
    /// part on this turn (the store just applied a batch, and the reader expects its write in
    /// the topology and the Search Tabs facts alike); otherwise the next frame publishes `part`.
    private func modelChanged(_ part: Parts) {
        if router.snapshots.hasWaiters { publishNow() } else { invalidate(part, notBefore: lastPublish + Self.modelChangeInterval) }
    }

    /// Publishes every part now. Compat intents call this so a CLI read that
    /// follows a CLI write sees it (the scheduled publish lands a frame later).
    func publishNow() {
        publish(.model)
    }

    /// Builds `parts` (each inside its own tracking, whose change republishes that part) and
    /// publishes them in one generation. `windows` alone republishes the window facts, unless a
    /// window came or went since the last topology publish (then the whole topology).
    private func publish(_ requested: Parts) {
        guard !isStopped else { return }
        var parts = requested
        // The topology carries the window facts.
        if parts.contains(.topology) { parts.remove(.windows) }
        pending.subtract(parts.contains(.topology) ? parts.union(.windows) : parts)
        let current = router.snapshots.current.topology
        var windowFacts: (windows: [ControlWindowInfo], focus: ControlFocus)?
        if parts.contains(.windows) {
            let windows = Self.windowInfos(services, cache: workspaceInfos)
            if windows.map(\.id) == current.windows.map(\.id) {
                windowFacts = (windows, Self.focus(services))
            } else {
                parts.remove(.windows)
                parts.insert(.topology)
            }
        }
        guard !parts.isEmpty else { return }
        let started = ContinuousClock.now
        if !parts.isDisjoint(with: .model) {
            lastPublish = started
            // A model part still pending keeps its wait.
            if pending.isDisjoint(with: .model) { notBefore = nil }
        }
        var topology: ControlTopology?
        if parts.contains(.topology) { topology = track(.topology) { Self.topology(services, cache: workspaceInfos) } }
        // The settings root itself may be nil (no settings controller): an outer nil is "not built".
        var settings: JSONValue??
        if parts.contains(.settings) { settings = .some(track(.settings) { services.settings?.snapshot.root }) }
        var tabSearch: ControlTabSearchFacts?
        if parts.contains(.tabSearch) { tabSearch = track(.tabSearch) { TabSearchFactsBuilder.facts(services) } }
        if parts == .windows, let windowFacts, windowFacts.windows == current.windows, windowFacts.focus == current.focus { return }
        router.snapshots.publish { snapshot in
            if let topology { snapshot.topology = topology }
            if let settings { snapshot.settings = settings }
            if let tabSearch { snapshot.tabSearch = tabSearch }
            if let windowFacts {
                snapshot.topology.windows = windowFacts.windows
                snapshot.topology.focus = windowFacts.focus
            }
        }
        guard let topology else { return }
        let elapsed = ContinuousClock.now - started
        // One entry per topology publish (`debug.timings` `control_publishes`). The tab count
        // walks every tab: only when a timing slot or the debug log wants it.
        DebugTimings.controlPublished(tabs: topology.tabCount, elapsed)
        if elapsed > .milliseconds(2) {
            logger.debug("control snapshot took \(elapsed.components.attoseconds / 1_000_000_000_000_000) ms for \(topology.tabCount) tabs")
        }
    }

    /// Builds one part inside its own tracking: a change of what it read republishes it.
    private func track<Value>(_ part: Parts, _ build: () -> Value) -> Value {
        withObservationTracking(build, onChange: { [weak self] in
            // Runs synchronously inside the mutation; publish after it lands.
            Task { @MainActor in self?.modelChanged(part) }
        })
    }

    /// The topology of every machine, window and focus as of now (also
    /// what Search Tabs lists in the palette).
    static func topology(_ services: AppServices, cache: ControlWorkspaceInfoCache? = nil) -> ControlTopology {
        var topology = ControlTopology(store: services.daemon.store, selectedTab: { [services] pane in
            services.paneController(for: pane)?.selectedTab?.id
        }, pages: services.controlPageFacts, cache: cache)
        if case .unavailable(let error) = services.daemon.startup { topology.daemonFailure = error.description }
        // Read inside tracking: every applied batch republishes, so a compat
        // read waiting on its write barrier wakes (CompatWriteBarrier).
        topology.daemonSequence = services.daemon.store.appliedSequence
        let machines = services.machines
        // Remote sessions' workspaces, qualified by session (data-model.md 1.3).
        topology.sessions = ControlSessions.sessions(machines: machines)
        for daemon in machines.remoteDaemons where daemon.store.isLoaded {
            let session = ControlSessions.key(daemon)
            topology.sessionSequences[session] = daemon.store.appliedSequence
            topology.workspaces += daemon.store.workspaces.map { model in
                var info = ControlWorkspaceInfo(model, cache: cache, selectedTab: { [services] pane in
                    services.paneController(for: pane)?.selectedTab?.id
                }, pages: services.controlPageFacts)
                info.sessionID = session
                info.machine = daemon.machineID
                return info
            }
        }
        // With the local daemon down, the remote sessions' workspaces are the
        // whole tree: resolve their public ids instead of passing them through.
        if !topology.isLoaded, topology.daemonFailure != nil, machines.remoteDaemons.contains(where: { $0.store.isLoaded }) {
            topology.isLoaded = true
        }
        topology.windows = windowInfos(services, cache: cache)
        topology.focus = focus(services)
        cache?.retain(services.daemon.store.workspaces
            + machines.remoteDaemons.filter { $0.store.isLoaded }.flatMap { $0.store.workspaces })
        return topology
    }

    /// Every window's control facts: its workspaces, whether it is key, visible or kept off
    /// screen, its focused pane, the workspaces its sidebar shows. O(windows) when the memos hold.
    /// Membership is read through `WindowRegistryStore.members(of:)`, which a key or order change
    /// (`WindowRegistry.recency`) does not move, so a window switch does not wake the topology.
    static func windowInfos(_ services: AppServices, cache: ControlWorkspaceInfoCache?) -> [ControlWindowInfo] {
        let windows: WindowManager = services.windows
        let machines = services.machines
        // The key window as `WindowManager.active` reads it (`AppServices.keyWindowSource`, NSApp's
        // key window), so `isKey` and the focus agree.
        let key = services.keyWindowSource()
        let infos: [ControlWindowInfo] = windows.controllers.map { controller in
            let members = windows.registry.members(of: controller.state.id)
            var info = ControlWindowInfo(
                id: controller.state.id,
                workspaceID: controller.state.workspaceID,
                workspaceIDs: members,
                isKey: key != nil && controller.window === key,
                isVisible: controller.window?.isVisible ?? false,
                focusedPaneID: controller.focusedPane?.pane.id
            )
            // What the user sees: windows kept off screen until a machine
            // reports one of their workspaces are hidden, and the count is
            // the sidebar's (current room, reported by a machine).
            info.isHidden = windows.awaitingContent[controller.state.id] != nil
            // Kept between publishes (rooms, pins and per-workspace reads stay
            // out of the publisher's own tracking): O(windows) when unchanged.
            let profile = controller.state.profileID
            let visible = {
                WindowProfiles.visible(members, profile: profile, machines: machines).filter { machines.workspace(id: $0) != nil }
            }
            info.visibleWorkspaceIDs = cache?.memo("window:" + controller.state.id, key: [members, [profile.rawValue]],
                                                   build: visible) ?? visible()
            return info
        }
        cache?.retainMemos(Set(windows.controllers.map { "window:" + $0.state.id }))
        return infos
    }

    /// Where the keyboard is: the active window, its workspace, focused pane and selected tab.
    static func focus(_ services: AppServices) -> ControlFocus {
        guard let active = services.windows.active else { return ControlFocus() }
        let pane = active.focusedPane
        // The strip's selected tab: a daemon tab, or an internal page
        // (Settings, Keyboard Shortcuts) or session browser tab the
        // daemon does not hold, as debug.focus reports it (nxdog53).
        return ControlFocus(windowID: active.state.id, workspaceID: active.state.workspaceID,
                            paneID: pane?.pane.id, tabID: pane?.selectedTab?.id ?? pane?.stripModel.selectedID?.rawValue)
    }
}
