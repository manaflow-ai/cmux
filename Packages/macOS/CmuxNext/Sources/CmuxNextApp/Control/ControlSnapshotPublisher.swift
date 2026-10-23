import AppKit
import CmuxNextControl
import CmuxNextDaemon
import Observation
import os

/// Publishes the control snapshot (architecture.md 5a) after the model
/// settles: at most once per display frame, and only when something the
/// snapshot reads changed.
///
/// The build runs inside Observation tracking, so any daemon record,
/// window state, focus, or settings property it read schedules the next
/// publish; every main-actor work queue frame and a window closing
/// invalidate explicitly. Key and activation changes (not observable) move
/// only the window facts (which window is key, the focus): they republish
/// those, O(windows), never every workspace (a Cmd-Tab, the palette's panel
/// taking the keys; perf-lead.md cause 6). Readers never touch main-actor
/// state: they get the last published value.
@MainActor
final class ControlSnapshotPublisher {
    private let router: ControlRouter
    private unowned let services: AppServices
    private let frames: any ControlFrameSource
    private var isScheduled = false
    /// The scheduled frame rebuilds everything (`publishNow`).
    private var needsFull = false
    /// The scheduled frame republishes the window facts (`publishWindows`).
    private var needsWindows = false
    /// A model-change publish waits until then (`modelChanged`); nil publishes on the next frame.
    private var notBefore: ContinuousClock.Instant?
    private var lastPublish = ContinuousClock.now
    /// Model changes (agent status ticks reach hundreds a second) publish at most this often:
    /// each publish maps every workspace. A read waiting on a write barrier still publishes at once.
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
        workspaceInfos.onStale = { [weak self] in self?.modelChanged() }
        // Read-your-writes for local state: a CLI mutation's effect on focus
        // or selection is in the snapshot before the next request is read.
        router.workQueue.setAfterFrame { [weak self] in self?.publishNow() }
        let center = NotificationCenter.default
        // A window that closes leaves the window list: everything.
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() } // main-proof: observer on queue: .main
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateWindows() } // main-proof: observer on queue: .main
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

    /// Schedules one publish on the next frame (coalesced); with `notBefore`,
    /// on the first frame from then on, unless a plain invalidate comes first.
    func invalidate(notBefore: ContinuousClock.Instant? = nil) {
        self.notBefore = notBefore.flatMap { new in isScheduled && needsFull ? self.notBefore.map { min($0, new) } : new }
        needsFull = true
        scheduleFrame()
    }

    /// Schedules the window facts (key window, focus) on the next frame, coalesced with any
    /// other publish: what a key or activation notice changes.
    private func invalidateWindows() {
        needsWindows = true
        scheduleFrame()
    }

    private func scheduleFrame() {
        guard !isScheduled, !isStopped else { return }
        isScheduled = true
        frames.scheduleFrame { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            if self.needsFull, let wait = self.notBefore, ContinuousClock.now < wait, !self.router.snapshots.hasWaiters {
                // The model publish waits; a key change in the meantime still shows on this frame.
                if self.needsWindows { self.publishWindows() }
                return self.invalidate(notBefore: wait)
            }
            if self.needsFull { self.publishNow() } else if self.needsWindows { self.publishWindows() }
        }
    }

    /// A compat read waiting on the write barrier publishes on this turn
    /// (the store just applied a batch); otherwise the next frame does.
    private func modelChanged() {
        if router.snapshots.hasWaiters { publishNow() } else { invalidate(notBefore: lastPublish + Self.modelChangeInterval) }
    }

    /// Publishes now. Compat intents call this so a CLI read that follows a
    /// CLI write sees it (the scheduled publish lands a frame later).
    func publishNow() {
        guard !isStopped else { return }
        let started = ContinuousClock.now
        (lastPublish, notBefore) = (started, nil)
        (needsFull, needsWindows) = (false, false)
        let (topology, settings, tabSearch) = withObservationTracking {
            (Self.topology(services, cache: workspaceInfos), services.settings?.snapshot.root, TabSearchFactsBuilder.facts(services))
        } onChange: { [weak self] in
            // Runs synchronously inside the mutation; publish after it lands.
            Task { @MainActor in self?.modelChanged() }
        }
        router.snapshots.publish { snapshot in
            snapshot.topology = topology
            snapshot.settings = settings
            snapshot.tabSearch = tabSearch
        }
        let elapsed = ContinuousClock.now - started
        // The tab count walks every tab: only when a timing slot or the debug log wants it.
        DebugTimings.controlPublished(tabs: topology.tabCount, elapsed)
        if elapsed > .milliseconds(2) {
            logger.debug("control snapshot took \(elapsed.components.attoseconds / 1_000_000_000_000_000) ms for \(topology.tabCount) tabs")
        }
    }

    /// Republishes the window facts only (``windowInfos(_:cache:)``, ``focus(_:)``): which window
    /// is key or visible and where the focus is, O(windows). The workspaces, Search Tabs facts and
    /// settings stay as the last full publish built them; their tracking from that publish is still
    /// armed, so a change of anything they read schedules a full one. A window that came or went
    /// since then publishes everything; unchanged facts publish nothing.
    private func publishWindows() {
        needsWindows = false
        guard !isStopped else { return }
        let current = router.snapshots.current.topology
        let windows = Self.windowInfos(services, cache: workspaceInfos)
        guard windows.map(\.id) == current.windows.map(\.id) else { return publishNow() }
        let focus = Self.focus(services)
        guard windows != current.windows || focus != current.focus else { return }
        router.snapshots.publish { snapshot in
            snapshot.topology.windows = windows
            snapshot.topology.focus = focus
        }
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
    static func windowInfos(_ services: AppServices, cache: ControlWorkspaceInfoCache?) -> [ControlWindowInfo] {
        let windows: WindowManager = services.windows
        let machines = services.machines
        let infos: [ControlWindowInfo] = windows.controllers.map { controller in
            let members = windows.registry.members(of: controller.state.id)
            var info = ControlWindowInfo(
                id: controller.state.id,
                workspaceID: controller.state.workspaceID,
                workspaceIDs: members,
                isKey: controller.window?.isKeyWindow ?? false,
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
