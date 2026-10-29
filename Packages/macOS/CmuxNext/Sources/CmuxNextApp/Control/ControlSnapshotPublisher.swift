import struct CmuxSafeConcurrency.OwnerReference
import AppKit
import CmuxNextControl
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Observation
import os

/// Publishes the control snapshot (architecture.md 5a) off the visible path
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task 039): a change sets a dirty bit, and one posted
/// `background` task publishes, however many changes came before that task runs. A reader waiting for a newer
/// snapshot (a write barrier, ``ControlSnapshotStore/snapshot(where:deadline:)``, or a read after a control
/// work-queue frame, ``ControlSnapshotStore/fresh(deadline:)``) raises the pending publish to `automation`, the
/// CLI's class, whether it came before or after the change. So a publish never runs inside the person's input
/// response (``MainFrameBudget`` holds both classes while it is open), and nothing builds per change. Chrome's
/// model: a best-effort task behind a dirty bit (`base/task/task_traits.h`, `TaskPriority::BEST_EFFORT`), raised
/// when a caller waits on it (`content/browser/scheduler/browser_task_queues.h`, a queue's priority set by who
/// needs it).
///
/// A publish maps only the workspaces whose entries went stale (``ControlWorkspaceInfoCache``). The build runs
/// inside a ``DirtyTracking``, so any daemon record, window state, focus, or settings property it read sets
/// the topology's dirty bit; key-window changes (not observable) set it explicitly. A model change leaves readers
/// the last published value; only a work-queue frame (the CLI's own main-actor write) marks the store stale, so the
/// next read builds first.
///
/// The daemon sequences (read-your-writes barriers) have a ``DirtyTracking`` of their own: a daemon batch
/// that changes nothing the topology shows (busy terminals' activity, a status tick elsewhere) only moves the
/// published sequences, in O(sessions) per publish, instead of mapping the topology again (perf-lead.md issue 5).
@MainActor
final class ControlSnapshotPublisher {
    private let router: ControlRouter
    private let servicesReference: OwnerReference<AppServices>
    /// The app's services, which own this through the control service; nil (reported) only once they are gone.
    private var services: AppServices? { servicesReference.resolve() }
    /// The app's main-thread scheduler (``AppServices/mainWork``), which runs every publish.
    private let mainWork: MainWorkScheduler
    private var isStopped = false
    /// Where the key-window and app-activation notices come from (key windows are not observable).
    private let appEvents: AppEvents
    private var notices: [EventSubscription] = []
    /// The classes of the publish tasks queued now: a change adds a task only when none of its class or a higher
    /// one is queued.
    private var queued: Set<BudgetedWorkClass> = []
    /// The sequences the published snapshot carries (a sequence-only publish skips equal ones).
    private var publishedSequences: ControlSequenceBarrier?
    /// Per-workspace control values kept between publishes (cx-9c8m).
    private let workspaceInfos = ControlWorkspaceInfoCache()
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "control.snapshot")
    private let publishOwner: MainTaskOwner
    /// Something the last build read changed since it ran.
    private let topologyTracking = DirtyTracking()
    /// A daemon sequence moved since the last publish read them.
    private let sequenceTracking = DirtyTracking()
    /// Topology builds and sequence-only publishes since start (tests, debug).
    private(set) var builds = 0
    private(set) var sequencePublishes = 0

    /// - Parameters:
    ///   - router: The control router whose snapshot store this publishes to.
    ///   - services: The app's services; their ``AppServices/mainWork`` runs every publish.
    ///   - appEvents: The app notices' one fan-out; nil: the services' (``AppServices/appEvents``). Tests pass one on
    ///     their own center.
    init(router: ControlRouter, services: AppServices, appEvents: AppEvents? = nil) {
        self.router = router
        servicesReference = OwnerReference(services: services)
        mainWork = services.mainWork
        self.appEvents = appEvents ?? services.appEvents
        publishOwner = services.mainWork.board.owner("control.snapshot.publish")
    }

    func start() {
        // It runs inside the entry's change (ControlWorkspaceInfoCache.onStale): it only queues the publish.
        workspaceInfos.onStale = { [weak self] in
            guard let self, self.workspaceInfos.hasStaleEntries else { return }
            self.invalidate()
        }
        // Read-your-writes for local state: a CLI mutation's effect on focus or selection is in the snapshot before
        // the next request is read. A work-queue frame only marks the snapshot stale; the next read builds it
        // (`ControlSnapshotStore.fresh`), once for any number of frames, and a read waiting on its barrier now.
        router.workQueue.setAfterFrame { [weak self] in self?.workQueueFrameRan() }
        let (work, owner) = (mainWork, publishOwner)
        router.snapshots.setRefresher({ [weak self] in self?.flush() }, waiterAdded: { [weak self] in
            // The reader's own request: one automation task, held while the person's input response is open.
            work.postFromAnyThread(.automation, owner: owner) { [weak self] in self?.waiterAdded() }
        })
        // raw-observer-allow: names the app's one AppEvents subscribes to (recipe R-notif); no observer of its own
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        // `always`: CLI reads need the key window and active state whatever is on screen; each post only sets a dirty bit.
        notices = names.map { name in
            appEvents.subscribe(name, owner: "ControlSnapshotPublisher") { [weak self] in self?.invalidate() }
        }
        // The first snapshot is background work too, so launch never waits for it. Until it is published the store
        // is stale: a read before it builds it in the reader's class.
        router.snapshots.markStale()
        invalidate()
    }

    func stop() {
        isStopped = true
        router.workQueue.setAfterFrame(nil)
        router.snapshots.setRefresher(nil)
        notices.removeAll()
    }

    /// Something the snapshot shows changed where the build's tracking does not see it (a key window, a workspace
    /// entry of the info cache): set it dirty and queue its publish.
    func invalidate() {
        topologyTracking.markDirty()
        topologyChanged()
    }

    /// A change the snapshot shows (its dirty bit is set): one background publish queued, or an automation one when
    /// a reader waits. Readers keep the last published value: a read never waits for a change it did not ask for.
    private func topologyChanged() {
        schedulePublish(router.snapshots.hasWaiters ? .automation : .background)
    }

    /// A daemon sequence moved (its dirty bit is set): the same queued publish as a topology change.
    private func sequencesChanged() {
        schedulePublish(router.snapshots.hasWaiters ? .automation : .background)
    }

    /// A reader started waiting for a newer snapshot (this is its automation task). The change it waits for usually
    /// came first (`action.run` awaits the daemon's idle, `after: "sync"` its round trip), so its publish is queued
    /// as background work: publish now instead. A change after this finds the reader itself (`hasWaiters` in
    /// ``topologyChanged()``).
    private func waiterAdded() {
        if router.snapshots.hasWaiters { flush() }
    }

    /// Queues one publish in `workClass`, unless one of that class or a higher one is queued.
    private func schedulePublish(_ workClass: BudgetedWorkClass) {
        guard !isStopped, !queued.contains(where: { $0.workClass <= workClass.workClass }) else { return }
        queued.insert(workClass)
        // node-free: CLI reads and their write barriers need the snapshot whatever is on screen.
        mainWork.post(workClass, owner: publishOwner) { [weak self] in
            self?.queued.remove(workClass)
            self?.flush()
        }
    }

    /// A control work-queue frame ran (a CLI call changed main-actor state): mark the snapshot stale; build it now
    /// only for a read waiting on its write barrier (this frame is that read's automation work).
    private func workQueueFrameRan() {
        router.snapshots.markStale()
        if router.snapshots.hasWaiters { publishNow() }
    }

    /// Publishes what changed since the last publish: the topology (with the sequences), or the sequences alone.
    /// A task that finds nothing pending (a higher-class one published first) does nothing. A cached entry stale
    /// before its `onStale` hop ran is a pending topology change too: sequences alone would go out beside it.
    private func flush() {
        guard !isStopped else { return }
        if router.snapshots.isStale || topologyTracking.isDirty || workspaceInfos.hasStaleEntries {
            publishNow()
        } else if sequenceTracking.isDirty {
            publishSequences()
        }
    }

    /// Builds and publishes now. It runs in a publish task or a work-queue frame a reader waits on: never in the
    /// turn of the change itself.
    func publishNow() {
        guard !isStopped, let services else { return }
        let started = ContinuousClock.now
        builds += 1
        let (built, settings, tabSearch) = topologyTracking.read({
            (Self.topology(services, cache: workspaceInfos, sequences: false), services.settings?.snapshot.root,
             TabSearchFactsBuilder.facts(services, cache: workspaceInfos))
        }, changed: { [weak self] in self?.topologyChanged() })
        // Outside the build's tracking: a sequence alone never rebuilds.
        var topology = built
        let sequences = readSequences(services)
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

    /// Publishes the daemon sequences alone: nothing the topology shows changed since its last build.
    private func publishSequences() {
        guard let services else { return }
        let sequences = readSequences(services)
        guard sequences != publishedSequences else { return }
        sequencePublishes += 1
        publishedSequences = sequences
        router.snapshots.publish { snapshot in
            Self.apply(sequences, to: &snapshot.topology)
        }
    }

    /// The daemon sequences as of now. A clean bit means the tracking armed by the last read has not fired, so
    /// only a dirty one arms the next.
    private func readSequences(_ services: AppServices) -> ControlSequenceBarrier {
        guard sequenceTracking.isDirty else { return Self.sequences(services) }
        return sequenceTracking.read({ Self.sequences(services) }, changed: { [weak self] in self?.sequencesChanged() })
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
            // One order for every reader: the sidebar's (`SidebarModel.workspaceOrder`), kept per structural change of its
            // rows (a move republishes it, a row's content patch does not); membership moves only on join or leave.
            let (model, joined) = (controller.sidebar.model, windows.registry.members(of: controller.state.id))
            let ordered = { model.workspaceOrder.ordering(joined) }
            let members = cache?.memo("order:" + controller.state.id, key: [joined, [String(model.observedSectionsRevision)]],
                                      build: ordered) ?? ordered()
            var info = ControlWindowInfo(id: controller.state.id, workspaceID: controller.state.workspaceID, workspaceIDs: members,
                                         isKey: controller.window?.isKeyWindow ?? false, isVisible: controller.window?.isVisible ?? false,
                                         focusedPaneID: controller.focusedPane?.pane.id)
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
        cache?.retainMemos(Set(windows.controllers.flatMap { ["window:" + $0.state.id, "order:" + $0.state.id] }))
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

/// A one-shot Observation tracking behind a dirty bit, the control snapshot publisher's change follower
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task 039). ``read(_:changed:)`` evaluates its read once per
/// publish. The first change of anything it read sets the bit, inside the mutation, and calls `changed` on the main
/// actor. Later changes cost nothing until the next read arms the next tracking, so nothing is read per change, and
/// the caller picks the class of the work that follows, not the change's cause. (A `ServiceObservation` reads
/// again on every flush and flushes a person-caused change inside the input-response pass. Here the read is the
/// whole topology build, and the reader that waits for it sets its class.)
///
/// ```swift
/// let topology = DirtyTracking()
/// let built = topology.read({ buildTopology() }, changed: { schedulePublish() })
/// // Later, in the publish task:
/// if topology.isDirty { publish() }
/// ```
private nonisolated final class DirtyTracking: Sendable {
    /// Set until the first read, and from the first change after a read until the next one. Set inside the
    /// mutation, which may be off the main actor.
    private let dirty = Atomic<Bool>(true)

    init() {}

    /// Something the last read read changed (or nothing was read yet).
    var isDirty: Bool { dirty.load(ordering: .acquiring) }

    /// Sets the bit for a change no tracking sees.
    func markDirty() { dirty.store(true, ordering: .releasing) }

    /// Clears the bit and evaluates `body` with a fresh tracking; its first change sets the bit and calls `changed`.
    @MainActor
    func read<T>(_ body: () -> T, changed: @escaping @MainActor @Sendable () -> Void) -> T {
        dirty.store(false, ordering: .releasing)
        // view-observation-allow: the read is the whole topology build, once per publish; ServiceObservation would build again per flush and in the person's input response, which this publisher must stay out of (task 039)
        return withObservationTracking(body) { [self] in
            markDirty()
            // main-hop-allow: models change on main, so this runs inline in the change's turn and only queues the publish, whose post names its class
            MainDelivery().run(changed)
        }
    }
}
