import AppKit
import CmuxNextControl
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Observation
import os

/// Publishes the control snapshot (architecture.md 5a) off the visible path
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task 039): a change marks it dirty, and one posted
/// `background` task builds and publishes it, however many changes came before that task runs. A read
/// that needs the snapshot fresh promotes the build to `automation` for its request (the CLI's class), so
/// a publish never runs in the person's input response (``MainFrameBudget`` holds both classes while it
/// is open) and nothing builds per change. Chrome's model: a best-effort task behind a dirty bit
/// (`base/task/task_traits.h`, `TaskPriority::BEST_EFFORT`), raised when a caller waits on it
/// (`content/browser/scheduler/browser_task_queues.h`, a queue's priority set by who needs it).
///
/// A publish maps only the workspaces whose entries went stale (``ControlWorkspaceInfoCache``). The build
/// runs inside Observation tracking, so any daemon record, window state, focus, or settings property it read
/// marks the snapshot dirty; key-window changes (not observable) and every main-actor work queue frame mark
/// it explicitly. Readers never touch main-actor state: they get the last published value, built first when
/// it is dirty (``ControlSnapshotStore/fresh()``).
///
/// The daemon sequences (read-your-writes barriers) are followed apart from the build, by a
/// ``ServiceObservation`` in the background class: a daemon batch that changes nothing the topology shows
/// (busy terminals' activity, a status tick elsewhere) only moves the published sequences, in O(sessions),
/// instead of mapping the topology again (perf-lead.md issue 5, the main thread under load).
@MainActor
final class ControlSnapshotPublisher {
    private let router: ControlRouter
    private unowned let services: AppServices
    private var isStopped = false
    private var observers: [MainActorObservation] = []
    private var sequenceObservation: ServiceObservation<ControlSequenceBarrier>?
    /// The class of the publish task queued now, nil when none is: a change while one is queued adds nothing,
    /// and only a waiting read adds a task of a higher class.
    private var queuedClass: BudgetedWorkClass?
    /// The sequences the published snapshot carries (a sequence-only publish skips equal ones).
    private var publishedSequences: ControlSequenceBarrier?
    /// Per-workspace control values kept between publishes (cx-9c8m).
    private let workspaceInfos = ControlWorkspaceInfoCache()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "control.snapshot")
    private let publishOwner: MainTaskOwner
    /// Something the last build read changed since it ran. Set in the tracking's callback, which runs
    /// synchronously inside the mutation, so a sequence change that follows in the same batch sees it.
    /// An atomic flag: the callback is not main-actor isolated.
    nonisolated private let topologyDirty = Atomic<Bool>(false)
    /// Topology builds and sequence-only publishes since start (tests, debug).
    private(set) var builds = 0
    private(set) var sequencePublishes = 0

    /// - Parameters:
    ///   - router: The control router whose snapshot store this publishes to.
    ///   - services: The app's services; their ``AppServices/mainWork`` runs every publish.
    init(router: ControlRouter, services: AppServices) {
        self.router = router
        self.services = services
        publishOwner = services.mainWork.board.owner("control.snapshot.publish")
    }

    func start() {
        workspaceInfos.onStale = { [weak self] in self?.topologyChanged() }
        // Read-your-writes for local state: a CLI mutation's effect on focus or selection is in the snapshot before
        // the next request is read. A work-queue frame only marks the snapshot stale; the next read builds it
        // (`ControlSnapshotStore.fresh`), once for any number of frames, and a read waiting on its barrier now.
        router.workQueue.setAfterFrame { [weak self] in self?.workQueueFrameRan() }
        let work = services.mainWork
        router.snapshots.setRefresher({ [weak self] in self?.publishIfStale() }, promoted: { [weak self] in
            // The reader's own request: one automation task, held while the person's input response is open.
            _ = await work.apply(.automation, owner: "control.snapshot.read") { [weak self] in self?.publishIfStale() }
        })
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(MainActorObservation(name, center: center) { [weak self] in
                self?.invalidate()
            })
        }
        // The first snapshot is background work too: launch never waits for it, and a read before it builds it.
        invalidate()
        // The read holds the services while the observation lives; the AppDelegate keeps them longer than this publisher.
        sequenceObservation = ServiceObservation(.background, owner: "control.snapshot.sequences", on: work) { [services = self.services] in
            Self.sequences(services)
        } apply: { [weak self] sequences in
            self?.sequencesChanged(sequences)
        }
    }

    func stop() {
        isStopped = true
        router.workQueue.setAfterFrame(nil)
        router.snapshots.setRefresher(nil)
        observers.removeAll()
        sequenceObservation?.cancel()
        sequenceObservation = nil
    }

    /// Something the snapshot shows changed where no tracking sees it (a key window): mark it dirty and queue
    /// its publish.
    func invalidate() {
        topologyChanged()
    }

    /// A change the snapshot shows: dirty for readers (``ControlSnapshotStore/fresh()`` builds it first), and one
    /// background publish queued, or an automation one when a read waits on its barrier.
    private func topologyChanged() {
        guard !isStopped else { return }
        topologyDirty.store(true, ordering: .releasing)
        router.snapshots.markStale()
        schedulePublish(router.snapshots.hasWaiters ? .automation : .background)
    }

    /// Queues one publish in `workClass`, unless one of that class or a higher one is queued.
    private func schedulePublish(_ workClass: BudgetedWorkClass) {
        guard !isStopped else { return }
        if let queuedClass, queuedClass.workClass <= workClass.workClass { return }
        queuedClass = workClass
        // node-free: CLI reads and their write barriers need the snapshot whatever is on screen.
        services.mainWork.post(workClass, owner: publishOwner) { [weak self] in self?.publishQueued(workClass) }
    }

    /// A queued publish: builds when a change is still unpublished (a read's build since may have published it).
    private func publishQueued(_ workClass: BudgetedWorkClass) {
        if queuedClass == workClass { queuedClass = nil }
        publishIfStale()
    }

    /// A control work-queue frame ran (a CLI call changed main-actor state): mark the snapshot stale; build it now
    /// only for a read waiting on its write barrier (this frame is that read's automation work).
    private func workQueueFrameRan() {
        router.snapshots.markStale()
        if router.snapshots.hasWaiters { publishNow() }
    }

    /// Builds and publishes when something changed since the last build: a read that found the snapshot stale,
    /// or a queued publish.
    private func publishIfStale() {
        if router.snapshots.isStale || topologyDirty.load(ordering: .acquiring) { publishNow() }
    }

    /// Builds and publishes now. It runs in a queued publish task, a read's automation task, or a work-queue frame
    /// a read waits on: never in the turn of the change itself.
    func publishNow() {
        guard !isStopped else { return }
        let started = ContinuousClock.now
        builds += 1
        topologyDirty.store(false, ordering: .releasing)
        let (built, settings, tabSearch) = withObservationTracking {
            (Self.topology(services, cache: workspaceInfos, sequences: false), services.settings?.snapshot.root,
             TabSearchFactsBuilder.facts(services, cache: workspaceInfos))
        } onChange: { [weak self] in
            // Runs synchronously inside the mutation: dirty at once, so a sequence change in the same batch waits
            // for this publish; the stale mark and the queued task follow on the main actor.
            self?.topologyDirty.store(true, ordering: .releasing)
            MainDelivery().run { [weak self] in self?.topologyChanged() }
        }
        // Outside the tracking: a sequence alone never rebuilds (the sequence observation).
        var topology = built
        let sequences = Self.sequences(services)
        Self.apply(sequences, to: &topology)
        publishedSequences = sequences
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

    /// The daemon sequences moved (the sequence observation's flush): publish them alone while the topology is
    /// clean; a pending topology publish carries them instead.
    private func sequencesChanged(_ sequences: ControlSequenceBarrier) {
        guard !isStopped, sequences != publishedSequences else { return }
        // A pending topology change (observed, or a work-queue frame's) is not covered by a sequence-only publish:
        // it would show the new sequences beside the old topology. Its publish reads the sequences as they are
        // then; a read waiting on its write barrier raises it to automation.
        if topologyDirty.load(ordering: .acquiring) || router.snapshots.isStale {
            if router.snapshots.hasWaiters { schedulePublish(.automation) }
            return
        }
        sequencePublishes += 1
        publishedSequences = sequences
        router.snapshots.publish { snapshot in
            Self.apply(sequences, to: &snapshot.topology)
        }
    }

    /// The home daemon's and each loaded remote session's applied sequence.
    static func sequences(_ services: AppServices) -> ControlSequenceBarrier {
        var sequences = ControlSequenceBarrier(home: services.daemon.store.appliedSequence)
        for daemon in services.machines.remoteDaemons where daemon.store.isLoaded {
            sequences.sessions[ControlSessions.key(daemon)] = daemon.store.appliedSequence
        }
        return sequences
    }

    /// `sequences` as the topology's daemon and session sequences.
    static func apply(_ sequences: ControlSequenceBarrier, to topology: inout ControlTopology) {
        topology.daemonSequence = sequences.home
        topology.sessionSequences = sequences.sessions
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
