import AppKit
import CmuxNextControl
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWakeups
import os

/// Publishes the control snapshot (architecture.md 5a) after the model
/// settles: at most once per dirty period, in the automation class, after
/// something the snapshot reads changed. A publish maps only the workspaces
/// whose entries went stale (``ControlWorkspaceInfoCache``), so there is no
/// interval between publishes to hide its cost.
///
/// The build is a ``FrameObservation`` with `.automation` delivery: any daemon
/// record, window state, focus, or settings property it read schedules one
/// rebuild and publish, which needs no display link, so a CLI or an agent
/// reads current state while no window is on screen. Key-window changes (not
/// observable) and every main-actor work queue frame invalidate explicitly.
/// Readers never touch main-actor state: they get the last published value.
///
/// The daemon sequences (read-your-writes barriers) are a second `.automation` observation, apart
/// from the build: a daemon batch that changes nothing the topology shows (busy terminals'
/// activity, a status tick elsewhere) only moves the published sequences, in O(sessions), instead of
/// mapping the topology again (every batch rebuilt it: perf-lead.md issue 5, the main thread under load).
@MainActor
final class ControlSnapshotPublisher {
    private let router: ControlRouter
    private unowned let services: AppServices
    private let frames: any ControlFrameSource
    private var isScheduled = false
    private var isStopped = false
    private var observers: [MainActorObservation] = []
    /// Per-workspace control values kept between publishes (cx-9c8m).
    private let workspaceInfos = ControlWorkspaceInfoCache()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "control.snapshot")
    /// The topology build, observed: a change to what it read rebuilds and publishes it.
    private var topologyWatch: FrameObservation<Build>?
    /// The daemon sequences, observed apart from the build.
    private var sequenceWatch: FrameObservation<ControlTopology>?
    /// The topology watch's dirty periods as of the last build. The watch counts one in the will-set of
    /// the change itself, so a sequence change later in the same batch sees the topology as dirty.
    private var builtThroughChange = 0
    /// Topology builds and sequence-only publishes since start (tests, debug).
    private(set) var builds = 0
    private(set) var sequencePublishes = 0

    init(router: ControlRouter, services: AppServices, frames: any ControlFrameSource) {
        self.router = router
        self.services = services
        self.frames = frames
    }

    func start() {
        workspaceInfos.onStale = { [weak self] in self?.modelChanged() }
        // Read-your-writes for local state: a CLI mutation's effect on focus or selection is in the snapshot before
        // the next request is read. A work-queue frame only marks the snapshot stale; the next read builds it
        // (`ControlSnapshotStore.fresh`), once for any number of frames, and a read waiting on its barrier now.
        router.workQueue.setAfterFrame { [weak self] in self?.workQueueFrameRan() }
        router.snapshots.setRefresher { [weak self] in self?.publishIfStale() }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(MainActorObservation(name, center: center) { [weak self] in
                self?.invalidate()
            })
        }
        let work = services.mainWork
        let topology = FrameObservation(owner: "control.snapshot", delivery: .automation, on: work) { [weak self] in
            self?.build() ?? Build()
        } onChange: { [weak self] build in
            self?.publish(build)
        }
        topologyWatch = topology
        publish(topology.value)
        sequenceWatch = FrameObservation(owner: "control.snapshot.sequences", delivery: .automation, on: work) { [weak self] in
            self.map { Self.sequences($0.services) } ?? ControlTopology()
        } onChange: { [weak self] sequences in
            self?.sequencesChanged(sequences)
        }
    }

    func stop() {
        isStopped = true
        topologyWatch?.cancel()
        sequenceWatch?.cancel()
        router.workQueue.setAfterFrame(nil)
        router.snapshots.setRefresher(nil)
        observers.removeAll()
    }

    /// Schedules one publish on the next frame (coalesced: every change before it lands in that publish).
    func invalidate() {
        guard !isScheduled, !isStopped else { return }
        isScheduled = true
        frames.scheduleFrame { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            self.publishNow()
        }
    }

    /// A control work-queue frame ran (a CLI call changed main-actor state): mark the snapshot stale; build it now
    /// only for a read waiting on its write barrier.
    private func workQueueFrameRan() {
        router.snapshots.markStale()
        if router.snapshots.hasWaiters { publishNow() }
    }

    /// A read found the snapshot stale: build and publish it, unless a publish since did.
    private func publishIfStale() {
        if router.snapshots.isStale { publishNow() }
    }

    /// A compat read waiting on the write barrier publishes on this turn
    /// (a cache entry just went stale); otherwise the next frame does.
    private func modelChanged() {
        if router.snapshots.hasWaiters { publishNow() } else { invalidate() }
    }

    /// Publishes now. Compat intents call this so a CLI read that follows a
    /// CLI write sees it (the scheduled publish lands a frame later).
    func publishNow() {
        guard !isStopped else { return }
        publish(build())
    }

    /// What one topology build read, published together, and the build's time.
    private struct Build {
        var topology = ControlTopology()
        var settings: CmuxNextSettings.JSONValue?
        var tabSearch = ControlTabSearchFacts()
        var elapsed: Duration = .zero
    }

    /// Maps the topology, the settings and the tab search facts: the topology watch's read, and an
    /// explicit publish's. It reads only what a change should rebuild for.
    private func build() -> Build {
        let started = ContinuousClock.now
        builds += 1
        let topology = Self.topology(services, cache: workspaceInfos, sequences: false)
        let settings = services.settings?.snapshot.root
        let tabSearch = TabSearchFactsBuilder.facts(services, cache: workspaceInfos)
        return Build(topology: topology, settings: settings, tabSearch: tabSearch, elapsed: ContinuousClock.now - started)
    }

    private func publish(_ build: Build) {
        guard !isStopped else { return }
        builtThroughChange = topologyWatch?.deliveriesScheduled ?? 0
        // Read here, not in the build: a sequence alone never rebuilds (the sequence watch).
        var topology = build.topology
        Self.applySequences(to: &topology, services)
        router.snapshots.publish(rebuilt: true) { snapshot in
            snapshot.topology = topology
            snapshot.settings = build.settings
            snapshot.tabSearch = build.tabSearch
        }
        // The cache keeps the tab count as entries change: no walk of every tab per publish.
        DebugTimings.controlPublished(tabs: workspaceInfos.tabCount, build.elapsed)
        if build.elapsed > .milliseconds(2) {
            logger.debug("control snapshot took \(build.elapsed.components.attoseconds / 1_000_000_000_000_000) ms for \(self.workspaceInfos.tabCount) tabs")
        }
    }

    /// Something the last build read changed and no build has run since.
    private var topologyDirty: Bool {
        (topologyWatch?.deliveriesScheduled ?? 0) != builtThroughChange
    }

    /// The sequence watch's apply: each applied batch either rides on the pending topology publish or
    /// moves only the published sequences.
    private func sequencesChanged(_ sequences: ControlTopology) {
        guard !isStopped else { return }
        // A pending topology change (observed, or a work-queue frame's) is not covered by a sequence-only publish:
        // it would show the new sequences beside the old topology.
        if topologyDirty || router.snapshots.isStale {
            // A topology change is pending: its publish reads the sequences as they are then. A read
            // waiting on its write barrier gets it now.
            if router.snapshots.hasWaiters { publishNow() }
            return
        }
        // Nothing the topology shows changed since the last build: only the sequences move.
        sequencePublishes += 1
        router.snapshots.publish { snapshot in
            snapshot.topology.daemonSequence = sequences.daemonSequence
            snapshot.topology.sessionSequences = sequences.sessionSequences
        }
    }

    /// The applied sequences alone, as the sequence watch reads them.
    private static func sequences(_ services: AppServices) -> ControlTopology {
        var sequences = ControlTopology()
        applySequences(to: &sequences, services)
        return sequences
    }

    /// The home daemon's and each loaded remote session's applied sequence, into `topology`.
    static func applySequences(to topology: inout ControlTopology, _ services: AppServices) {
        topology.daemonSequence = services.daemon.store.appliedSequence
        for daemon in services.machines.remoteDaemons where daemon.store.isLoaded {
            topology.sessionSequences[ControlSessions.key(daemon)] = daemon.store.appliedSequence
        }
    }

    /// The topology of every machine, window and focus as of now (also
    /// what Search Tabs lists in the palette). `sequences: false` leaves the daemon sequences at 0
    /// (the publisher reads them outside its tracking).
    static func topology(_ services: AppServices, cache: ControlWorkspaceInfoCache? = nil, sequences: Bool = true) -> ControlTopology {
        let windows: WindowManager = services.windows
        let selectedTab: (PaneModel) -> String? = { [services] pane in services.paneController(for: pane)?.selectedTab?.id }
        let pages = services.controlPageFacts
        // With the cache, map only changed workspaces and the panes whose app facts can be set: those a window
        // mounts (`paneController(for:)`) and those with page tabs (9% of main at 400 workspaces, a576 churn bench).
        let scope = cache.map { _ in ControlAppFactScope(paneIDs: services.pages.paneKeys
            + windows.controllers.flatMap { $0.content?.panes.values.map(\.pane.id) ?? [] }) }
        var topology = ControlTopology(store: services.daemon.store, selectedTab: selectedTab, pages: pages, cache: cache, scope: scope)
        if case .unavailable(let error) = services.daemon.startup { topology.daemonFailure = error.description }
        if sequences { topology.daemonSequence = services.daemon.store.appliedSequence }
        let machines = services.machines
        // Remote sessions' workspaces, qualified by session (data-model.md 1.3).
        topology.sessions = ControlSessions.sessions(machines: machines)
        var slots: Set<String> = [ControlWorkspaceInfoCache.homeSlot]
        for daemon in machines.remoteDaemons where daemon.store.isLoaded {
            let (session, machine) = (ControlSessions.key(daemon), daemon.machineID)
            if sequences { topology.sessionSequences[session] = daemon.store.appliedSequence }
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
