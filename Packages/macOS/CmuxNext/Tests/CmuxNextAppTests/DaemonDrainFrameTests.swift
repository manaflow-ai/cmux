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
    /// One workspace, one screen, one pane with `tabs` tabs on surfaces 1...tabs.
    private func service(tabs: Int, mainWork: MainWorkScheduler) -> DaemonService {
        let service = DaemonService(mainWork: mainWork)
        let pane = PaneSnapshot(id: 1, tabs: (1...tabs).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), title: "t") })
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        service.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        // Never started: no socket is touched.
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-drain-frame-test.sock"))
        service.store.driver = StoreDriver(connection: connection, inbox: EventInbox(), scheduler: service.drainScheduler)
        return service
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

    /// p06-scheduler-032: the drain applies each event with its own cause. In one batch, an agent's
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

    /// p06-scheduler-032: a local intent shows the person's change in the input-response pass; the
    /// same intent made inside an automation scope (an agent driving the action) stays automation.
    @Test func aLocalIntentAppliesAsPersonUnlessAutomationMadeIt() throws {
        let harness = CauseHarness()
        let service = service(tabs: 2, mainWork: harness.work)
        let store = service.store
        let mine = harness.watch("mine") { store.tab(surface: 1)?.name ?? "" }
        let agent = harness.watch("agent") { store.tab(surface: 2)?.name ?? "" }
        store.intend(.renameTab(surface: 1, name: "mine"), transaction: ClientTransactionID(rawValue: "rename-mine"))
        harness.work.causes.withCause(.automation) {
            store.intend(.renameTab(surface: 2, name: "agent"), transaction: ClientTransactionID(rawValue: "rename-agent"))
        }
        #expect(harness.work.causes.flushPersonCaused() == 1, "the person's intent did not reach the input-response pass")
        #expect(harness.flushes["mine"] == [nil, .frame])
        #expect(harness.flushes["agent"] == [nil])
        harness.frame()
        #expect(harness.flushes["agent"] == [nil, .automation])
        harness.stop(mine, agent)
    }
}

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
