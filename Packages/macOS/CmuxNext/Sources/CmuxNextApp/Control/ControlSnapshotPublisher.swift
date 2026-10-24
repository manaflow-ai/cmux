import AppKit
import CmuxNextControl
import CmuxNextCompat
import CmuxNextDaemon
import Observation
import os

/// Publishes the control snapshot (architecture.md 5a) only when a reader needs it.
///
/// A change to anything the last build read (Observation tracking of the build), a key-window change (not
/// observable) and every control work-queue frame mark the snapshot stale; nothing is built, no frame is asked for and
/// no timer runs while nobody reads. A reader that needs main-actor state as of now (`ControlSnapshotStore.fresh`) or a
/// newer snapshot (a barrier read) waits; its arrival (`ControlSnapshotStore.waiterAdditions`) makes this build at once,
/// charged to the main-thread budget's automation class and held back while it may not run (a person's pending input,
/// the frame's visible updates). While readers keep waiting, changes build at most once per display frame. A build maps
/// only the workspaces whose entries went stale (``ControlWorkspaceInfoCache``). Readers never touch main-actor state:
/// they get a published value, and a reader that reads none of it (`system.ping`) never waits.
///
/// The daemon sequences (read-your-writes barriers) are tracked apart from the build: a daemon batch
/// that changes nothing the topology shows (busy terminals' activity, a status tick elsewhere) only
/// moves the published sequences, in O(sessions), instead of mapping the topology again (every batch
/// rebuilt it: perf-lead.md issue 5, the main thread under load).
@MainActor
final class ControlSnapshotPublisher {
    private let router: ControlRouter
    private unowned let services: AppServices
    private let frames: any ControlFrameSource
    /// A build is asked for and has not run (coalesced: every change before it lands in that build).
    private var buildRequested = false
    private var isStopped = false
    /// Iterates the store's waiter additions on the main actor while started.
    private var waiterTask: Task<Void, Never>?
    private var observers: [MainActorObservation] = []
    /// Per-workspace control values kept between publishes (cx-9c8m).
    private let workspaceInfos = ControlWorkspaceInfoCache()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "control.snapshot")
    /// Something the last build read changed since it ran. Set in the observation callback, which runs
    /// synchronously inside the mutation, so a sequence change that follows in the same batch sees it.
    /// An atomic flag: the callback is not main-actor isolated.
    nonisolated private let topologyDirty = Atomic<Bool>(false)
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
        // Read-your-writes for local state: a CLI mutation's effect on focus or selection is in the snapshot the next
        // request reads. A work-queue frame only marks the snapshot stale; the reader that needs it builds it, once for
        // any number of frames before it.
        router.workQueue.setAfterFrame { [weak self] in self?.changed() }
        let additions = router.snapshots.waiterAdditions()
        waiterTask = Task { @MainActor [weak self] in
            for await _ in additions { self?.readerWaits() }
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(MainActorObservation(name, center: center) { [weak self] in
                self?.changed()
            })
        }
        publishNow()
        observeSequences()
    }

    func stop() {
        isStopped = true
        router.workQueue.setAfterFrame(nil)
        waiterTask?.cancel()
        waiterTask = nil
        observers.removeAll()
    }

    /// Main-actor state the snapshot shows changed (a tracked read, a key-window change, a work-queue frame): the
    /// snapshot is stale. Readers already waiting get one build on the next display frame (coalesced); with none,
    /// nothing runs until one reads.
    private func changed() {
        router.snapshots.markStale()
        if router.snapshots.hasWaiters { requestBuild(soon: false) }
    }

    /// A reader started waiting: a stale store (or a change the last build missed) is built at once; otherwise its
    /// barrier may be a daemon sequence that moved, which a sequence-only publish answers.
    private func readerWaits() {
        guard !isStopped else { return }
        if router.snapshots.isStale || topologyDirty.load(ordering: .acquiring) {
            requestBuild(soon: true)
        } else {
            publishSequences()
        }
    }

    /// Asks for one build: on the next main run loop turn (`soon`: a reader waits now) or the next display frame (a
    /// change while readers wait). Coalesced.
    private func requestBuild(soon: Bool) {
        guard !buildRequested, !isStopped else { return }
        buildRequested = true
        let run: @MainActor @Sendable () -> Void = { [weak self] in self?.buildWhenAllowed() }
        if soon { frames.scheduleSoon(run) } else { frames.scheduleFrame(run) }
    }

    /// The asked-for build, charged to the main-thread budget's automation class; while that class may not run (a
    /// person's pending input, the frame's visible updates) it waits for the next display frame.
    private func buildWhenAllowed() {
        guard !isStopped else { return }
        if let budget = frames.mainFrameBudget, !budget.mayRun(.automation) {
            frames.scheduleFrame { [weak self] in self?.buildWhenAllowed() }
            return
        }
        buildRequested = false
        if let budget = frames.mainFrameBudget {
            budget.run(.automation, owner: "control.publish") { publishNow() }
        } else {
            publishNow()
        }
    }

    /// A tracked read of the last build changed (or the workspace cache went stale).
    private func modelChanged() {
        changed()
    }

    /// Publishes now. Compat intents call this so a CLI read that follows a
    /// CLI write sees it (the scheduled publish lands a frame later).
    func publishNow() {
        guard !isStopped else { return }
        let started = ContinuousClock.now
        builds += 1
        topologyDirty.store(false, ordering: .releasing)
        let (built, settings, tabSearch) = withObservationTracking {
            (Self.topology(services, cache: workspaceInfos, sequences: false), services.settings?.snapshot.root,
             TabSearchFactsBuilder.facts(services, cache: workspaceInfos))
        } onChange: { [weak self] in
            // Runs synchronously inside the mutation; publish after it lands.
            self?.topologyDirty.store(true, ordering: .releasing)
            Task { @MainActor in self?.modelChanged() }
        }
        // Outside the tracking: a sequence alone never rebuilds (observeSequences).
        var topology = built
        Self.applySequences(to: &topology, services)
        // The build read the main actor's state as of now: it covers every work-queue frame before it.
        router.snapshots.publish(coversMainActorState: true) { snapshot in
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

    /// Re-arms the daemon sequence observation: each applied batch either rides on the pending
    /// topology publish or moves only the published sequences.
    private func observeSequences() {
        guard !isStopped else { return }
        withObservationTracking {
            var probe = ControlTopology()
            Self.applySequences(to: &probe, services)
        } onChange: { [weak self] in
            Task { @MainActor in self?.sequencesChanged() }
        }
    }

    private func sequencesChanged() {
        guard !isStopped else { return }
        observeSequences()
        // A pending topology change (observed, or a work-queue frame's) is not covered by a sequence-only publish:
        // a read waiting on these sequences would get a snapshot without that change. The build reads the sequences
        // as they are then; a waiter added later asks for it (readerWaits), so no order of frame, batch and waiter
        // leaves a waiter to its deadline.
        if topologyDirty.load(ordering: .acquiring) || router.snapshots.isStale {
            if router.snapshots.hasWaiters { requestBuild(soon: true) }
            return
        }
        publishSequences()
    }

    /// Nothing the topology shows changed since the last build: only the daemon sequences move (O(sessions)).
    private func publishSequences() {
        sequencePublishes += 1
        var sequences = ControlTopology()
        Self.applySequences(to: &sequences, services)
        router.snapshots.publish { snapshot in
            snapshot.topology.daemonSequence = sequences.daemonSequence
            snapshot.topology.sessionSequences = sequences.sessionSequences
        }
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
