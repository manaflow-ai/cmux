import CmuxNextControl
import CmuxNextDaemonService
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Observation
import Testing
import CmuxNextWakeupsTestSupport

/// The control work queue on the app's budgeted batcher, through the real path
/// (`FrameBatcher` -> `FrameBatchQueue` -> `FrameScheduler` of a ``MainWorkScheduler``): work
/// left after a frame keeps the budgeted display link running until the backlog is gone.
@MainActor @Suite(.timeLimit(.minutes(1))) struct BudgetedFrameBatcherTests {
    /// A drain that leaves work re-armed through a run loop hop: the hop landed after the tick, the
    /// frame queue found nothing pending and went idle, the scheduler invalidated the link (and
    /// cancelled its stall timer), and the hop then made a new link. One link per frame of backlog.
    @Test func aRequestBacklogKeepsOneDisplayLinkAcrossItsFrames() {
        let clock = BatcherBudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let links = LinkCounter()
        // The stall deadline's clock never moves: only the frames the test fires tick.
        let work = MainWorkScheduler.testing(budget: budget, clock: ManualClock()) { _ in links.make() }
        let batcher = FrameBatcher(owner: "Control.frames", budgeted: .automation, on: work)
        let queue = MainActorWorkQueue(frameSource: batcher)
        let deadline = ContinuousClock.now + .seconds(30)
        let end = ContinuousClock.now + .seconds(10)
        // Twelve 2 ms requests: a frame's 4 ms of scheduled work runs two, so ten are left after
        // the first drain and each frame leaves more behind until the last.
        for index in 0..<12 {
            Task.detached {
                _ = try await queue.run(connection: ControlConnectionID(rawValue: UInt64(index + 1)), method: "workspace.move", deadline: deadline) {
                    clock.advance(ms: 2)
                }
            }
        }
        while queue.stats.pending + queue.stats.executed < 12, ContinuousClock.now < end { usleep(1_000) }
        // The idle queue's first drain runs on a main run loop turn (`scheduleSoon`).
        while queue.stats.executed == 0, ContinuousClock.now < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        var frame = 0.0
        while queue.stats.pending > 0, ContinuousClock.now < end {
            frame += 1
            clock.advance(ms: 17)
            work.frameDidFire(timestamp: frame, refreshInterval: 1.0 / 60)
            // Lets a re-arm that went through the run loop land, as it would in the app.
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        #expect(queue.stats.pending == 0)
        #expect(frame >= 4, "the backlog took several frames (\(frame))")
        #expect(links.made == 1, "the budgeted link was rebuilt \(links.made - 1) times over \(Int(frame)) frames of backlog")
        #expect(!work.frames.hasLink, "the link goes away with the backlog")
    }

    /// p06-scheduler-207, through the app's path (`SidebarRowFeed` on a budgeted `visible`
    /// SidebarRows queue, its causes from `mainWork.causes`): 400 rows an automation change marked,
    /// then one a person's change marked. One row a flush and 1 ms a row map, so each automation
    /// flush is a 1 ms task. The person's row patches first, in the first frame; the automation
    /// rows spread over frames in the order they were marked (with no input pending the visible
    /// class takes its 2.5 ms share and then idle time up to the 4 ms of scheduled work: 4 flushes a
    /// frame, so 100 frames).
    @Test func aPersonRowPatchRunsInTheFirstFrameWhileAutomationRowPatchesSpreadOut() {
        let clock = BatcherBudgetClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), clock: ManualClock()) { _ in CountedLink() }
        let rows = FrameBatcher(owner: "SidebarRows", budgeted: .visible, on: work)
        let causes = work.causes
        let feed = SidebarRowFeed(cause: { causes.currentCause }, rowsPerBudgetedFlush: 1,
                                  schedule: { cause, flush in rows.queue.enqueue(cause: cause, flush) })
        let mine = 400
        let models = (0...mine).map { _ in RowTitle() }
        let ids = (0...mine).map { WorkspaceID("row \($0)") }
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let log = RunLog()
        let cost = MapCost(clock: clock)
        feed.onChange = { changed in log.ran += changed.compactMap { positions[$0.id] } }
        feed.beginPass(inputs: 0)
        for (position, id) in ids.enumerated() {
            let model = models[position]
            _ = feed.row(id, machine: .local) {
                cost.charge()
                return SidebarWorkspace(id: id, machineID: .local, title: model.title)
            }
        }
        _ = feed.fill([])
        cost.msPerMap = 1

        causes.withCause(.automation) { for model in models.dropLast() { model.title += " 2" } }
        causes.withCause(.person) { models[mine].title = "mine 2" }
        #expect(rows.queue.unbudgetedCount == 1, "the person's flush waits for no budget")
        #expect(rows.queue.count == 401, "one automation flush a row")
        #expect(log.ran.isEmpty, "nothing maps in the change's turn")

        var perFrame: [Int] = []
        var frame = 0.0
        while rows.queue.count > 0, frame < 1_000 {
            frame += 1
            clock.advance(ms: 17)
            let before = log.ran.count
            work.frameDidFire(timestamp: frame, refreshInterval: 1.0 / 60)
            perFrame.append(log.ran.count - before)
        }
        #expect(log.ran.first == mine, "the person's row patches first")
        #expect((perFrame.first ?? 0) >= 1, "the person's row patches in the first frame")
        #expect(log.ran.count == 401)
        #expect(Array(log.ran.dropFirst()) == Array(0..<mine), "the automation rows patch in the order they were marked")
        #expect((perFrame.first ?? 0) <= 6, "the first frame ran the person's patch and at most a budget's worth: \(perFrame)")
        let late = perFrame.dropFirst().filter { $0 > 5 }
        #expect(late.isEmpty, "no later frame ran more than 5 automation flushes: \(late)")
        #expect(frame >= 80, "the automation rows spread over \(Int(frame)) frames")
    }

    /// The person's turn is open (a key that expects a frame): the queue's person item goes to the
    /// budget's `InputResponsePass` (p06-scheduler-206) and runs before that turn's commit, on a fake
    /// run loop. Frontend, program and automation items stay for the next frame: the frontend's
    /// unbudgeted with the frame clients, the others under the class budget. A person item queued
    /// before the turn opened is not the pass's: it waits for the frame too.
    @Test func theInputResponsePassRunsThePersonsItemBeforeTheCommit() {
        let clock = BatcherBudgetClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), clock: ManualClock()) { _ in CountedLink() }
        let rows = FrameBatcher(owner: "SidebarRows", budgeted: .visible, on: work)
        let loop = CommitRunLoop()
        let pass = InputResponsePass(budget: work.budget, runLoop: loop)
        rows.queue.enqueue(cause: .person) { loop.events.append("early person") }
        #expect(rows.queue.unbudgetedCount == 1, "outside the person's turn the pass takes nothing")

        work.budget.noteDiscreteInput(expectsFrame: true)
        rows.queue.enqueue(cause: .automation) { loop.events.append("automation") }
        rows.queue.enqueue(cause: .program) { loop.events.append("program") }
        rows.queue.enqueue(cause: .frontend) { loop.events.append("frontend") }
        rows.queue.enqueue(cause: .person) { loop.events.append("person") }
        #expect(rows.queue.count == 4, "the pass took the person's item")
        loop.turn()
        #expect(loop.events == ["person", "commit"], "the pass ran only the person's item, before the commit")
        #expect(pass.stats.items == 1)

        clock.advance(ms: 17)
        work.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(loop.events == ["person", "commit", "early person", "frontend", "automation", "program"])
        #expect(rows.queue.count == 0)
    }

    /// SidebarRows passes the store change's cause: each cause gets its own flushes, and the person
    /// flush maps only the rows a person's change marked, not the ones automation marked. The causes
    /// are the scheduler's (`mainWork.causes`), the instance the app's writers scope.
    @Test func theRowFeedFlushesPersonRowsApartFromAutomationRows() {
        let clock = BatcherBudgetClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), clock: ManualClock()) { _ in CountedLink() }
        let causes = work.causes
        let titles = RowTitles()
        let scheduled = ScheduledFlushes()
        let feed = SidebarRowFeed(cause: { causes.currentCause }, schedule: { cause, flush in scheduled.flushes.append((cause: cause, work: flush)) })
        var patched: [String] = []
        feed.onChange = { rows in patched += rows.map(\.title) }
        feed.beginPass(inputs: 0)
        let agent = WorkspaceID("agent"), mine = WorkspaceID("mine")
        _ = feed.row(agent, machine: .local) { SidebarWorkspace(id: agent, machineID: .local, title: titles.agent) }
        _ = feed.row(mine, machine: .local) { SidebarWorkspace(id: mine, machineID: .local, title: titles.mine) }
        _ = feed.fill([])

        causes.withCause(.automation) { titles.agent = "agent 2" }
        causes.withCause(.person) { titles.mine = "mine 2" }
        #expect(scheduled.flushes.map { $0.cause } == [.automation, .person])

        scheduled.flushes[1].work()
        #expect(patched == ["mine 2"], "the person flush maps the person's row only")
        scheduled.flushes[0].work()
        #expect(patched == ["mine 2", "agent 2"])

        causes.withCause(.automation) { titles.agent = "agent 3" }
        #expect(scheduled.flushes.map { $0.cause } == [.automation, .person, .automation], "a flush that ran is scheduled again")
    }
}

/// What the queued work ran, in order.
@MainActor
private final class RunLog {
    var ran: [Int] = []
}

/// The flushes a row feed scheduled, with their causes.
@MainActor
private final class ScheduledFlushes {
    var flushes: [(cause: ObservationCause, work: @MainActor @Sendable () -> Void)] = []
}

/// Two rows' content.
@MainActor @Observable
private final class RowTitles {
    var agent = "agent"
    var mine = "mine"
}

/// One row's content.
@MainActor @Observable
private final class RowTitle {
    var title = "row"
}

/// What a row map costs on the test's budget clock (none while the rows are first filled).
@MainActor
private final class MapCost {
    private let clock: BatcherBudgetClock
    var msPerMap = 0.0

    init(clock: BatcherBudgetClock) { self.clock = clock }

    func charge() { clock.advance(ms: msPerMap) }
}

/// A run loop whose turn runs its queued blocks, then the commit stage's observers in order, and
/// logs `commit` where Core Animation's observer (order 2,000,000) runs.
@MainActor
private final class CommitRunLoop: InputResponseRunLoop {
    var events: [String] = []
    private var observers: [CommitStageObserver] = []
    private var blocks: [@MainActor () -> Void] = []

    func observeBeforeCommit(order: CFIndex, _ handler: @escaping @MainActor () -> Void) -> any InputResponseObservation {
        let observer = CommitStageObserver(order: order, handler: handler)
        observers.append(observer)
        return observer
    }

    func perform(_ work: @escaping @MainActor () -> Void) {
        blocks.append(work)
    }

    func turn() {
        let queued = blocks
        blocks.removeAll()
        for block in queued { block() }
        var committed = false
        for observer in observers.filter(\.isValid).sorted(by: { $0.order < $1.order }) {
            if !committed, observer.order >= 2_000_000 {
                events.append("commit")
                committed = true
            }
            if observer.isValid { observer.handler() }
        }
        if !committed { events.append("commit") }
        observers.removeAll { !$0.isValid }
    }
}

private final class CommitStageObserver: InputResponseObservation {
    let order: CFIndex
    let handler: @MainActor () -> Void
    private(set) var isValid = true

    init(order: CFIndex, handler: @escaping @MainActor () -> Void) {
        self.order = order
        self.handler = handler
    }

    func invalidate() { isValid = false }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class BatcherBudgetClock {
    private var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [unowned self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

/// Counts the display links the scheduler makes.
@MainActor
private final class LinkCounter {
    private(set) var made = 0

    func make() -> any FrameLink {
        made += 1
        return CountedLink()
    }
}

@MainActor
private final class CountedLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
