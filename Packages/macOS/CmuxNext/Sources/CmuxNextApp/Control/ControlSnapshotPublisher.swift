import AppKit
import CmuxNextControl
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Observation
import os

/// Publishes the control snapshot (architecture.md 5a) after the model
/// settles: one build per dirty period, in the automation class. A publish
/// maps only the workspaces whose entries went stale
/// (``ControlWorkspaceInfoCache``), so there is no interval between
/// publishes to hide its cost.
///
/// The build's Observation tracking is only a dirty bit: the first change to
/// anything it read (a daemon record, window state, focus, settings) sets
/// `topologyDirty` inside the mutation and posts one publish in the
/// automation class, which needs no display link, so a CLI or an agent reads
/// current state while no window is on screen. A cached workspace entry's
/// change (``ControlWorkspaceInfoCache/onStale``) and a key-window change (not
/// observable) set the same bit, and every build clears it and re-arms the
/// tracking, so the paths coalesce into one build. Blink does the same: a
/// change only marks the frame for an update (`PageAnimator::ScheduleVisualUpdate`,
/// third_party/blink/renderer/core/page/page_animator.cc) and one lifecycle
/// update runs for any number of them. Readers never touch main-actor state:
/// they get the last published value.
///
/// The daemon sequences (read-your-writes barriers) are a `.automation` ``FrameObservation``
/// apart from the build (an O(sessions) read): a daemon batch that changes nothing the topology
/// shows (busy terminals' activity, a status tick elsewhere) only moves the published sequences
/// instead of mapping the topology again (perf-lead.md issue 5, the main thread under load).
@MainActor
final class ControlSnapshotPublisher {
    private let router: ControlRouter
    private unowned let services: AppServices
    private var isStopped = false
    private var observers: [MainActorObservation] = []
    /// Per-workspace control values kept between publishes (cx-9c8m).
    private let workspaceInfos = ControlWorkspaceInfoCache()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "control.snapshot")
    /// A change the last build read, or an invalidate, came after that build. Set inside the mutation, on its
    /// thread (an atomic), so a sequence change later in the same batch sees it; its false-to-true edge posts the
    /// dirty period's one publish, and only a build clears it.
    nonisolated private let topologyDirty = Atomic<Bool>(false)
    /// The armed tracking's generation: a build replaces the tracking, and the replaced one's callback is stale.
    nonisolated private let trackingGeneration = Atomic<UInt64>(0)
    /// Read under the build's tracking; writing it fires, and so drops, the tracking a build replaces.
    private let trackingCancel = ControlSnapshotTrackingCancel()
    nonisolated private let work: MainWorkScheduler
    /// The publish task's owner, interned once.
    nonisolated private let publishOwner: MainTaskOwner
    /// The daemon sequences, observed apart from the build.
    private var sequenceWatch: FrameObservation<ControlTopology>?
    /// Topology builds and sequence-only publishes since start (tests, debug).
    private(set) var builds = 0
    private(set) var sequencePublishes = 0

    init(router: ControlRouter, services: AppServices) {
        self.router = router
        self.services = services
        work = services.mainWork
        publishOwner = services.mainWork.board.owner("control.snapshot")
    }

    func start() {
        workspaceInfos.onStale = { [weak self] in self?.cachedEntryChanged() }
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
        publishNow()
        sequenceWatch = FrameObservation(owner: "control.snapshot.sequences", delivery: .automation, on: work) { [weak self] in
            self.map { Self.sequences($0.services) } ?? ControlTopology()
        } onChange: { [weak self] sequences in
            self?.sequencesChanged(sequences)
        }
    }

    func stop() {
        isStopped = true
        sequenceWatch?.cancel()
        trackingGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        trackingCancel.epoch &+= 1
        router.workQueue.setAfterFrame(nil)
        router.snapshots.setRefresher(nil)
        observers.removeAll()
    }

    /// Marks the topology dirty and posts its publish, unless a publish is already pending: a change the build's
    /// tracking cannot see (the key window, a cached entry).
    func invalidate() {
        guard !isStopped, !topologyDirty.exchange(true, ordering: .acquiringAndReleasing) else { return }
        work.post(.automation, owner: publishOwner) { [weak self] in self?.publishIfDirty() }
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

    /// A cached workspace entry's tracking fired (one hop after the change). A build since then rebuilt the entry and
    /// left nothing to do. A compat read waiting on the write barrier publishes on this turn; otherwise the pending
    /// publish does.
    private func cachedEntryChanged() {
        guard workspaceInfos.hasStaleEntries else { return }
        if router.snapshots.hasWaiters { publishNow() } else { invalidate() }
    }

    /// The posted publish: it finds nothing when a build since ended the dirty period.
    private func publishIfDirty() {
        if topologyDirty.load(ordering: .acquiring) { publishNow() }
    }

    /// Builds and publishes now and ends the dirty period. Compat intents call this so a CLI read that follows a
    /// CLI write sees it; the posted publish then finds nothing to do.
    func publishNow() {
        guard !isStopped else { return }
        let started = ContinuousClock.now
        builds += 1
        topologyDirty.store(false, ordering: .releasing)
        let generation = trackingGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        trackingCancel.epoch &+= 1
        let cancel = trackingCancel
        // view-observation-allow: a dirty bit over the whole build; a FrameObservation reads its track again in each will-set, here a full topology build per change
        let (built, settings, tabSearch) = withObservationTracking {
            _ = cancel.epoch
            return (Self.topology(services, cache: workspaceInfos, sequences: false), services.settings?.snapshot.root,
                    TabSearchFactsBuilder.facts(services, cache: workspaceInfos))
        } onChange: { [weak self] in
            self?.trackingFired(generation)
        }
        // Outside the tracking: a sequence alone never rebuilds (the sequence watch).
        var topology = built
        Self.applySequences(to: &topology, services)
        router.snapshots.publish(rebuilt: true) { snapshot in
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

    /// The build's tracking fired, inside the mutation and on its thread: the first change of the dirty period posts
    /// its one publish. It reads nothing: the new value is not set yet.
    private nonisolated func trackingFired(_ generation: UInt64) {
        guard trackingGeneration.load(ordering: .acquiring) == generation,
              !topologyDirty.exchange(true, ordering: .acquiringAndReleasing) else { return }
        work.postFromAnyThread(.automation, owner: publishOwner) { [weak self] in self?.publishIfDirty() }
    }

    /// The sequence watch's apply: each applied batch either rides on the pending topology publish or
    /// moves only the published sequences.
    private func sequencesChanged(_ sequences: ControlTopology) {
        guard !isStopped else { return }
        // A sequence-only publish beside a pending topology change would show the new sequences with the old
        // topology. The pending publish (or, for a work-queue frame's change, the next read) reads them as they are
        // then; a read waiting on its write barrier gets it now.
        if topologyDirty.load(ordering: .acquiring) || router.snapshots.isStale {
            if router.snapshots.hasWaiters { publishNow() }
            return
        }
        // A cached entry changed in this batch (marked inside its mutation); its `onStale` hop may not have run yet.
        if workspaceInfos.hasStaleEntries {
            if router.snapshots.hasWaiters { publishNow() } else { invalidate() }
            return
        }
        let published = router.snapshots.current.topology
        // A build since the change already published them.
        guard published.daemonSequence != sequences.daemonSequence || published.sessionSequences != sequences.sessionSequences
        else { return }
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

/// Read under the publisher's build tracking; writing it fires, and so drops, that tracking (the registrar keeps an
/// armed tracking until it fires).
@MainActor @Observable
private final class ControlSnapshotTrackingCancel {
    var epoch: UInt64 = 0
}
