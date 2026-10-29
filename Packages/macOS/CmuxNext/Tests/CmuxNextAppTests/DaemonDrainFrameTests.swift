import CmuxNextActions
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// The daemon store's event batches on the service's own drain batcher (`DaemonService.drainScheduler`),
/// built on a test ``MainWorkScheduler`` ticked by hand with the app's main-thread budget (review 2 of
/// pl-main-bc, findings 1 and 2).
///
/// e04d1798d04 moved the drain to the budgeted visible class and applied a batch in 32-event slices:
/// the echo of an action with no intent (close other tabs, close a workspace from the palette or the
/// CLI) waited a frame while the person typed, a transaction longer than one slice showed half applied,
/// and a sustained event rate above what one slice per frame applied grew the inbox until it collapsed
/// into an overflow and a full snapshot apply.
@MainActor @Suite struct DaemonDrainFrameTests {
    /// ``tree(tabs:workspaces:titles:)`` applied; a resync reads `snapshot` (default: the unstarted
    /// connection's, which fails at once).
    private func service(tabs: Int, workspaces: Int = 1, mainWork: MainWorkScheduler, deadlines: MainDeadlineScheduler? = nil,
                         snapshot: (@MainActor @Sendable () async throws -> (tree: DaemonTree, barrier: UInt64))? = nil) -> DaemonService {
        let service = deadlines.map { DaemonService(mainWork: mainWork, deadlines: $0, appEvents: AppEvents(center: NotificationCenter())) }
            ?? DaemonService(mainWork: mainWork)
        service.store.apply(snapshot: Self.tree(tabs: tabs, workspaces: workspaces))
        // Never started: no socket is touched.
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-drain-frame-test.sock"))
        service.store.driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: service.drainScheduler, snapshot: snapshot)
        return service
    }

    /// Workspace 1: one screen, one pane with `tabs` tabs on surfaces 1...tabs, titled `titles[surface]`
    /// or "t". Workspaces 2...`workspaces`: one tab each, on surface 100 + the workspace's handle.
    private static func tree(tabs: Int, workspaces: Int = 1, titles: [Int: String] = [:]) -> DaemonTree {
        DaemonTree(workspaces: (1...workspaces).map { handle in
            let surfaces = handle == 1 ? Array(1...tabs) : [100 + handle]
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(handle)),
                                    tabs: surfaces.map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: titles[$0] ?? "t") })
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(handle)), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(handle)), key: nil, name: "w\(handle)", screens: [screen])
        })
    }

    /// What the pump does for a non-empty inbox (`DaemonStore.run`), minus the main run loop hop.
    private func scheduleDrain(_ service: DaemonService) {
        let store = service.store
        service.drainScheduler.queue.enqueue { store.drain() }
    }

    /// Close Other Tabs has no intent: the person sees it only through the daemon's echo. The whole
    /// transaction (199 tab closes, more than one slice) applies in the next frame while a key is pending.
    @Test func anActionsEchoAppliesWholeInTheNextFrameWhileThePersonTypes() throws {
        let input = TypingInput()
        input.pending = true
        let budget = MainFrameBudget(input: input, uptimeNanos: AdvancingClock(stepNanos: 1_000_000).read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in StillFrameLink() }
        let service = service(tabs: 200, mainWork: work)
        let driver = try #require(service.store.driver)
        let transaction = ClientTransactionID(rawValue: "close-other-tabs")
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .titleChanged(surface: 1, title: "kept")))
        for surface in 2...200 {
            let delta = TabDelta(workspace: 1, screen: 1, pane: 1, surface: SurfaceID(rawValue: UInt64(surface)), index: nil,
                                 entity: TabSnapshot(surface: SurfaceID(rawValue: UInt64(surface)), title: "t"),
                                 clientTransactionID: transaction)
            _ = driver.inbox.append(DaemonEventEnvelope(sequence: UInt64(surface), event: .tabClosed(delta)))
        }
        scheduleDrain(service)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        let tabs = try #require(service.store.workspaces.first?.screens.first?.panes.first?.tabs)
        #expect(tabs.map(\.surface) == [1], "the echo waited for a later frame, or applied in part (\(tabs.count) tabs left)")
        #expect(tabs.first?.title == "kept")
        #expect(driver.inbox.bufferedCount == 0)
    }

    /// 200 agent transitions a frame (agent statuses never coalesce), with every frame's budget
    /// spent: each frame applies what arrived, so the inbox never grows, never overflows, and no
    /// full snapshot apply follows.
    @Test func aSustainedEventRateNeverGrowsTheInbox() throws {
        let budget = MainFrameBudget(uptimeNanos: AdvancingClock(stepNanos: 1_000_000).read)
        let work = MainWorkScheduler.testing(budget: budget) { _ in StillFrameLink() }
        let service = service(tabs: 200, mainWork: work)
        let store = service.store
        let driver = try #require(store.driver)
        var sequence: UInt64 = 0
        for frame in 1...60 {
            for surface in 1...200 {
                sequence += 1
                let status = AgentStatus(surface: SurfaceID(rawValue: UInt64(surface)), state: frame.isMultiple(of: 2) ? .idle : .working,
                                         source: "hook", agent: "claude", updatedAtMs: sequence)
                _ = driver.inbox.append(DaemonEventEnvelope(sequence: sequence, event: .agentChanged(status)))
            }
            scheduleDrain(service)
            work.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
            #expect(driver.inbox.bufferedCount == 0, "frame \(frame): \(driver.inbox.bufferedCount) events left for later frames")
            #expect(!store.isResyncing, "frame \(frame): the inbox overflowed into a snapshot")
        }
        #expect(!store.snapshotMemo.untracked)
        #expect(store.agents.bySurface[200]?.state == .idle)
    }

    /// The drain applies each event with its own cause. In one batch, an agent's
    /// title (automation) and the echo of the person's own change (person): the view only the agent
    /// changed flushes as automation, behind a pending key; the person's flushes in the
    /// input-response pass. Before, the whole batch applied as program and both flushed as visible.
    @Test func eachEventOfABatchFlushesInTheClassOfItsOwnCause() throws {
        let harness = CauseHarness()
        let service = service(tabs: 2, mainWork: harness.work)
        let store = service.store
        let driver = try #require(store.driver)
        let agent = harness.watch("agent") { store.tab(surface: 1)?.title ?? "" }
        let mine = harness.watch("mine") { store.tab(surface: 2)?.title ?? "" }
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .titleChanged(surface: 1, title: "agent 2"), cause: .automation))
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 2, event: .titleChanged(surface: 2, title: "mine 2"), cause: .person))
        store.drain()
        #expect(harness.work.causes.currentCause == .program, "the drain left an event's cause current")
        #expect(harness.work.causes.flushPersonCaused() == 1, "the person's echo did not reach the input-response pass")
        #expect(harness.flushes["mine"] == [nil, .frame])
        #expect(harness.flushes["agent"] == [nil], "the agent's title flushed as person")
        harness.input.pending = true
        harness.frame()
        #expect(harness.flushes["agent"] == [nil], "the agent's title ran ahead of a pending key")
        harness.input.pending = false
        harness.frame()
        #expect(harness.flushes["agent"] == [nil, .automation])
        #expect(harness.flushes["mine"] == [nil, .frame], "the person's view applied twice")
        harness.stop(agent, mine)
    }

    /// p06-scheduler-032 review: an action's local intent takes the cause of who started the run
    /// (`ActionRegistry.runScoped`). The person's rename (origin `user`: keyboard, menu, palette)
    /// shows in the input-response pass; the same action from the CLI (an agent's `cmux rename-tab`,
    /// as `RegistryControlBridge.perform` runs it) flushes as automation, behind a pending key. The
    /// first fix applied every intent outside an automation scope as person, and nothing opened one.
    @Test func anActionsIntentTakesTheCauseOfWhoStartedTheRun() throws {
        let harness = CauseHarness()
        let store = service(tabs: 2, mainWork: harness.work).store
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "test.renameTab", title: "Rename Tab", category: .other)])
        registry.causes = harness.work.causes
        registry.bindEffect("test.renameTab", effect: { invocation in
            let surface = SurfaceID(rawValue: UInt64(invocation.arguments["surface"]?.intValue ?? 0))
            store.intend(.renameTab(surface: surface, name: "renamed"), transaction: .generate())
            return .done
        })
        let mine = harness.watch("mine") { store.tab(surface: 1)?.name ?? "" }
        let agent = harness.watch("agent") { store.tab(surface: 2)?.name ?? "" }
        #expect(registry.perform("test.renameTab", invocation: ActionInvocation(arguments: ["surface": .int(1)])))
        #expect(registry.perform("test.renameTab", invocation: ActionInvocation(arguments: ["surface": .int(2)], origin: .cli)))
        #expect(harness.work.causes.currentCause == .program, "a run left its cause current")
        #expect(harness.work.causes.flushPersonCaused() == 1, "the CLI's intent reached the person's input-response pass")
        #expect(harness.flushes["mine"] == [nil, .frame])
        #expect(harness.flushes["agent"] == [nil])
        harness.input.pending = true
        harness.frame()
        #expect(harness.flushes["agent"] == [nil], "the CLI's rename ran ahead of a pending key")
        harness.input.pending = false
        harness.frame()
        #expect(harness.flushes["agent"] == [nil, .automation])
        harness.stop(mine, agent)
    }

    /// p06-scheduler-032 review: what a batch publishes as a whole takes the cause of the events
    /// that changed it, not the batch's highest. An agent moves workspace 2 (automation) in the batch
    /// of the echo of the person's title: the sidebar and the tab list flush as automation; the
    /// first fix flushed them in the person's input-response pass.
    @Test func theSidebarAndTabListOfABatchFlushWithTheCauseOfWhatChangedThem() throws {
        let harness = CauseHarness()
        let store = service(tabs: 1, workspaces: 2, mainWork: harness.work).store
        let driver = try #require(store.driver)
        let entity = try #require(Self.tree(tabs: 1, workspaces: 2).workspaces.last)
        let mine = harness.watch("mine") { store.tab(surface: 1)?.title ?? "" }
        let sidebar = harness.watch("sidebar") { store.sidebarSections.flatMap(\.workspaces).map { "\($0.handle.rawValue)" }.joined(separator: ",") }
        let list = harness.watch("list") { "\(store.tabListRevision)" }
        let move = WorkspaceDelta(workspace: 2, index: 0, entity: entity, workspaceRevision: store.workspaceRevision + 1)
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .workspaceMoved(move), cause: .automation))
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 2, event: .titleChanged(surface: 1, title: "mine 2"), cause: .person))
        store.drain()
        #expect(store.workspaces.map(\.handle) == [2, 1], "the move did not apply")
        #expect(harness.work.causes.flushPersonCaused() == 1, "the agent's move reached the person's input-response pass")
        #expect(harness.flushes["mine"] == [nil, .frame])
        harness.input.pending = true
        harness.frame()
        #expect(harness.flushes["sidebar"] == [nil], "the sidebar ran ahead of a pending key")
        #expect(harness.flushes["list"] == [nil], "the tab list ran ahead of a pending key")
        harness.input.pending = false
        harness.frame()
        #expect(harness.flushes["sidebar"] == [nil, .automation])
        #expect(harness.flushes["list"] == [nil, .automation])
        harness.stop(mine, sidebar, list)
    }

    /// p06-scheduler-032 review: a resync's snapshot applies with the cause of the batch that asked
    /// for it, and the next resync starts from none. The person's echo needs a snapshot: what it
    /// changes shows in the input-response pass; a later resync an agent's batch asks for applies as
    /// automation.
    @Test func aResyncAppliesWithTheCauseOfTheBatchThatAskedForIt() async throws {
        let harness = CauseHarness()
        let snapshots = SnapshotScript(Self.tree(tabs: 2, titles: [2: "mine 2"]))
        let store = service(tabs: 2, mainWork: harness.work, snapshot: snapshots.read).store
        let driver = try #require(store.driver)
        let agent = harness.watch("agent") { store.tab(surface: 1)?.title ?? "" }
        let mine = harness.watch("mine") { store.tab(surface: 2)?.title ?? "" }
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil), cause: .person))
        store.drain()
        await store.refresh()
        #expect(harness.work.causes.flushPersonCaused() == 1, "the person's resync did not reach the input-response pass")
        #expect(harness.flushes["mine"] == [nil, .frame])
        snapshots.next(Self.tree(tabs: 2, titles: [1: "agent 2", 2: "mine 2"]))
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 100, event: .treeChanged(transaction: nil), cause: .automation))
        store.drain()
        await store.refresh()
        #expect(harness.work.causes.flushPersonCaused() == 0, "the agent's resync applied with the person's cause")
        harness.frame()
        #expect(harness.flushes["agent"] == [nil, .automation])
        harness.stop(agent, mine)
    }

    /// p06-scheduler-032 review: a failed snapshot with no retry (disconnected, or the retry budget
    /// spent) keeps no cause. The first fix kept the person's for the next resync, so an agent's
    /// batch that asked for it much later applied its whole snapshot as person.
    @Test func aFailedResyncWithNoRetryKeepsNoCauseForTheNextOne() async throws {
        let harness = CauseHarness()
        let snapshots = SnapshotScript(Self.tree(tabs: 2, titles: [1: "agent 2"]), failures: 1)
        let store = service(tabs: 2, mainWork: harness.work, snapshot: snapshots.read).store
        let driver = try #require(store.driver)
        let agent = harness.watch("agent") { store.tab(surface: 1)?.title ?? "" }
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil), cause: .person))
        store.drain()
        await store.refresh()
        #expect(snapshots.reads == 1)
        #expect(store.resyncRetry == nil, "not connected: no retry")
        #expect(store.causes.resync == .program, "the failed resync kept its cause with no retry to apply it")
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 2, event: .treeChanged(transaction: nil), cause: .automation))
        store.drain()
        await store.refresh()
        #expect(harness.work.causes.flushPersonCaused() == 0, "the agent's resync applied with the failed one's person cause")
        harness.frame()
        #expect(harness.flushes["agent"] == [nil, .automation])
        harness.stop(agent)
    }

    /// p06-scheduler-032 review: the retry of a failed snapshot applies it with the cause of the
    /// batch that asked for it. p06-scheduler-339 fixer: the retry is a visible main deadline on the
    /// app's deadlines (no DemandTimer on main): it waits for its wake, then runs as a posted task.
    @Test func theRetryOfAFailedResyncKeepsItsCause() async throws {
        let harness = CauseHarness()
        let rig = MainDeadlineRig(posting: harness.work)
        let snapshots = SnapshotScript(Self.tree(tabs: 2, titles: [2: "mine 2"]), failures: 1)
        let store = service(tabs: 2, mainWork: harness.work, deadlines: rig.deadlines, snapshot: snapshots.read).store
        store.connectionState = .connected(DaemonIdentity(generation: DaemonGeneration(rawValue: "drain-cause-test")))
        let driver = try #require(store.driver)
        let mine = harness.watch("mine") { store.tab(surface: 2)?.title ?? "" }
        _ = driver.inbox.append(DaemonEventEnvelope(sequence: 1, event: .treeChanged(transaction: nil), cause: .person))
        store.drain()
        let refreshed = Task { await store.refresh() }
        for _ in 0..<10_000 where store.resyncRetry == nil { await Task.yield() }
        let retry = try #require(store.resyncRetry, "the failed snapshot armed no retry")
        #expect(retry.isScheduled && rig.hasArmedWake, "the retry is not a deadline on the app's wake-up queue")
        #expect(snapshots.reads == 1, "the retry ran before its wake")
        rig.fire()
        harness.frame() // the retry's posted visible task
        await refreshed.value
        #expect(snapshots.reads == 2, "the failed snapshot was not retried once")
        #expect(harness.work.causes.flushPersonCaused() == 1, "the retry did not apply with the person's cause")
        #expect(harness.flushes["mine"] == [nil, .frame])
        harness.stop(mine)
    }
}

/// The snapshots a test's resync reads (``StoreDriver/snapshot``): `failures` refusals, then the
/// current tree, its barrier 10 past the last one.
@MainActor
private final class SnapshotScript {
    private(set) var reads = 0
    private var tree: DaemonTree
    private var failures: Int
    private var barrier: UInt64 = 0

    init(_ tree: DaemonTree, failures: Int = 0) {
        self.tree = tree
        self.failures = failures
    }

    /// The next reads return `tree`, with a new barrier.
    func next(_ tree: DaemonTree) {
        self.tree = tree
    }

    var read: @MainActor @Sendable () async throws -> (tree: DaemonTree, barrier: UInt64) {
        { [self] in try self.take() }
    }

    private func take() throws(SnapshotRefused) -> (tree: DaemonTree, barrier: UInt64) {
        reads += 1
        if failures > 0 {
            failures -= 1
            throw SnapshotRefused()
        }
        barrier += 10
        return (tree, barrier)
    }
}

/// The daemon did not answer a snapshot (a test's ``SnapshotScript``).
private struct SnapshotRefused: Error {}

/// A scheduler on a clock the test moves, kept ticking by one frame client, and the work class each
/// observation's apply ran in (nil: the first apply, in the caller's turn).
@MainActor
private final class CauseHarness {
    let input: TypingInput
    let work: MainWorkScheduler
    private(set) var flushes: [String: [MainWorkClass?]] = [:]
    private let clock: SteppedClock
    private let keeper: FrameClient
    private var timestamp: Double = 0

    init() {
        let input = TypingInput(), clock = SteppedClock()
        self.input = input
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: clock.read)) { _ in StillFrameLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Observes `read` on a visible node; each apply records the class it ran in under `owner`.
    func watch(_ owner: String, read: @escaping @MainActor () -> String) -> VisibleObservation<String> {
        VisibleObservation(VisibilityNode(root: "window", own: .visible), owner: "test.\(owner)", on: work, read: read) { [self] _ in
            flushes[owner, default: []].append(work.budget.board.running?.workClass)
        }
    }

    /// One display frame, 17 ms after the last one.
    func frame() {
        clock.advance(ms: 17)
        timestamp += 1
        work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
    }

    /// Cancels `watches` and stops the frames.
    func stop(_ watches: VisibleObservation<String>...) {
        for watch in watches { watch.cancel() }
        keeper.deactivate()
    }
}

/// A clock that moves only when the test moves it.
@MainActor
private final class SteppedClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in now } }
    func advance(ms: Double) { now += UInt64((ms * 1_000_000).rounded()) }
}

/// A clock that moves `stepNanos` at every read, so every budget check sees time spent. `read`
/// holds the clock (the budget keeps only the closure).
@MainActor
private final class AdvancingClock {
    private var now: UInt64 = 1_000_000_000
    private let step: UInt64
    init(stepNanos: UInt64) { step = stepNanos }
    var read: () -> UInt64 { { [self] in now += step; return now } }
}

@MainActor
private final class TypingInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

@MainActor
private final class StillFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
