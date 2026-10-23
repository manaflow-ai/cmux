import AppKit
import CmuxNextControl
import CmuxNextCompat
import CmuxNextDaemon
import Observation
import os

/// Publishes the control snapshot (architecture.md 5a) after the model
/// settles: at most once per display frame, and only when something the
/// snapshot reads changed.
///
/// The build runs inside Observation tracking, so any daemon record,
/// window state, focus, or settings property it read schedules the next
/// publish; key-window changes (not observable) and every main-actor work
/// queue frame invalidate explicitly. Readers never touch main-actor state:
/// they get the last published value.
@MainActor
final class ControlSnapshotPublisher {
    private let router: ControlRouter
    private unowned let services: AppServices
    /// When the next publish runs: the next frame, or a model change's delay (`modelChanged`).
    private let pacer: ControlPublishPacer
    private var lastPublish = ContinuousClock.now
    /// Model changes (agent status ticks reach hundreds a second) publish at most this often:
    /// each publish maps every workspace. A read waiting on a write barrier still publishes at once.
    static let modelChangeInterval: Duration = .milliseconds(100)
    private var isStopped = false
    private var observers: [MainActorObservation] = []
    /// Per-workspace control values kept between publishes (cx-9c8m).
    private let workspaceInfos = ControlWorkspaceInfoCache()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "control.snapshot")

    init(router: ControlRouter, services: AppServices, frames: any ControlFrameSource) {
        self.router = router
        self.services = services
        pacer = ControlPublishPacer(frames: frames)
        pacer.publish = { [weak self] in self?.publishNow() }
        pacer.isUrgent = { [weak router] in router?.snapshots.hasWaiters ?? false }
    }

    func start() {
        workspaceInfos.onStale = { [weak self] in self?.modelChanged() }
        // Read-your-writes for local state: a CLI mutation's effect on focus
        // or selection is in the snapshot before the next request is read.
        router.workQueue.setAfterFrame { [weak self] in self?.publishNow() }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(MainActorObservation(name, center: center) { [weak self] in
                self?.invalidate()
            })
        }
        publishNow()
    }

    func stop() {
        isStopped = true
        pacer.stop()
        router.workQueue.setAfterFrame(nil)
        observers.removeAll()
    }

    /// Schedules one publish on the next frame (coalesced).
    func invalidate() {
        guard !isStopped else { return }
        pacer.requestFrame()
    }

    /// A compat read waiting on the write barrier publishes on this turn
    /// (the store just applied a batch); otherwise the first frame at least
    /// `modelChangeInterval` after the last publish does.
    private func modelChanged() {
        guard !isStopped else { return }
        if router.snapshots.hasWaiters { return publishNow() }
        pacer.request(after: lastPublish + Self.modelChangeInterval - .now)
    }

    /// Publishes now. Compat intents call this so a CLI read that follows a
    /// CLI write sees it (the scheduled publish lands a frame later).
    func publishNow() {
        guard !isStopped else { return }
        let started = ContinuousClock.now
        lastPublish = started
        pacer.cancel()
        let (topology, settings, tabSearch) = withObservationTracking {
            (Self.topology(services, cache: workspaceInfos), services.settings?.snapshot.root, TabSearchFactsBuilder.facts(services, cache: workspaceInfos))
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
        // The cache keeps the tab count as entries change: no walk of every tab per publish.
        DebugTimings.controlPublished(tabs: workspaceInfos.tabCount, elapsed)
        if elapsed > .milliseconds(2) {
            logger.debug("control snapshot took \(elapsed.components.attoseconds / 1_000_000_000_000_000) ms for \(self.workspaceInfos.tabCount) tabs")
        }
    }

    /// The topology of every machine, window and focus as of now (also
    /// what Search Tabs lists in the palette).
    static func topology(_ services: AppServices, cache: ControlWorkspaceInfoCache? = nil) -> ControlTopology {
        let windows: WindowManager = services.windows
        let selectedTab: (PaneModel) -> String? = { [services] pane in services.paneController(for: pane)?.selectedTab?.id }
        let pages = services.controlPageFacts
        // With the cache, map only changed workspaces and the panes whose app facts can be set: those a window
        // mounts (`paneController(for:)`) and those with page tabs (9% of main at 400 workspaces, a576 churn bench).
        let scope = cache.map { _ in ControlAppFactScope(paneIDs: services.pages.paneKeys
            + windows.controllers.flatMap { $0.content?.panes.values.map(\.pane.id) ?? [] }) }
        var topology = ControlTopology(store: services.daemon.store, selectedTab: selectedTab, pages: pages, cache: cache, scope: scope)
        if case .unavailable(let error) = services.daemon.startup { topology.daemonFailure = error.description }
        // Read inside tracking: every applied batch republishes, so a compat
        // read waiting on its write barrier wakes (CompatWriteBarrier).
        topology.daemonSequence = services.daemon.store.appliedSequence
        let machines = services.machines
        // Remote sessions' workspaces, qualified by session (data-model.md 1.3).
        topology.sessions = ControlSessions.sessions(machines: machines)
        var slots: Set<String> = [ControlWorkspaceInfoCache.homeSlot]
        for daemon in machines.remoteDaemons where daemon.store.isLoaded {
            let (session, machine) = (ControlSessions.key(daemon), daemon.machineID)
            topology.sessionSequences[session] = daemon.store.appliedSequence
            let slot = slots.insert("\(session)|\(machine)").memberAfterInsert
            topology.workspaces += ControlTopology.workspaces(of: daemon.store, cache: cache, slot: slot, scope: scope,
                                                              selectedTab: selectedTab, pages: pages) { info in
                (info.sessionID, info.machine) = (session, machine)
            }
        }
        cache?.retainLists(slots)
        // With the local daemon down, the remote sessions' workspaces are the
        // whole tree: resolve their public ids instead of passing them through.
        if !topology.isLoaded, topology.daemonFailure != nil, machines.remoteDaemons.contains(where: { $0.store.isLoaded }) {
            topology.isLoaded = true
        }
        topology.windows = windows.controllers.map { controller in
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
        if let active = windows.active {
            let pane = active.focusedPane
            // The strip's selected tab: a daemon tab, or an internal page
            // (Settings, Keyboard Shortcuts) or session browser tab the
            // daemon does not hold, as debug.focus reports it (nxdog53).
            topology.focus = ControlFocus(windowID: active.state.id, workspaceID: active.state.workspaceID,
                                          paneID: pane?.pane.id, tabID: pane?.selectedTab?.id ?? pane?.stripModel.selectedID?.rawValue)
        }
        return topology
    }
}
