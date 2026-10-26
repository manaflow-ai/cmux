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

    /// p06-scheduler-207: a budgeted queue's person work is never budgeted. 400 automation row
    /// patches of 1 ms each and then one person patch: the person one runs first, in the first
    /// frame, and the automation ones spread over frames (with no input pending a class may take the
    /// whole 4 ms of scheduled work a frame: at most 5 patches a frame, so 80 frames or more).
    @Test func aPersonPatchRunsInTheNextFrameWhileAutomationPatchesSpreadOut() {
        let clock = BatcherBudgetClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), clock: ManualClock()) { _ in CountedLink() }
        let rows = FrameBatcher(owner: "SidebarRows", budgeted: .visible, on: work)
        let log = RunLog()
        for index in 0..<400 {
            rows.queue.enqueue(cause: .automation) {
                clock.advance(ms: 1)
                log.ran.append(index)
            }
        }
        rows.queue.enqueue(cause: .person) { log.ran.append(-1) }
        #expect(rows.queue.unbudgetedCount == 1)
        #expect(rows.queue.count == 401)

        var perFrame: [Int] = []
        var frame = 0.0
        while rows.queue.count > 0, frame < 1_000 {
            frame += 1
            clock.advance(ms: 17)
            let before = log.ran.count
            work.frameDidFire(timestamp: frame, refreshInterval: 1.0 / 60)
            perFrame.append(log.ran.count - before)
        }
        #expect(log.ran.first == -1, "the person patch runs first, in the first frame")
        #expect(log.ran.count == 401)
        #expect(Array(log.ran.dropFirst()) == Array(0..<400), "the automation patches keep their order")
        #expect((perFrame.max() ?? 0) <= 6, "no frame ran more than the person patch and a budget's worth: \(perFrame.max() ?? 0)")
        #expect(frame >= 60, "the automation patches spread over \(Int(frame)) frames")
    }

    /// The input-response pass runs a queue's person and frontend work in the input's own turn;
    /// the automation work stays queued for the budget.
    @Test func theInputResponsePassRunsOnlyPersonAndFrontendWork() {
        let clock = BatcherBudgetClock()
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read), clock: ManualClock()) { _ in CountedLink() }
        let rows = FrameBatcher(owner: "SidebarRows", budgeted: .visible, on: work)
        let log = RunLog()
        rows.queue.enqueue(cause: .automation) { log.ran.append(0) }
        rows.queue.enqueue(cause: .program) { log.ran.append(1) }
        rows.queue.enqueue(cause: .frontend) { log.ran.append(2) }
        rows.queue.enqueue(cause: .person) { log.ran.append(3) }

        #expect(rows.queue.runUnbudgeted() == 2)
        #expect(log.ran == [2, 3])
        #expect(rows.queue.count == 2, "automation and program work keep the class budget")
        #expect(rows.queue.runUnbudgeted() == 0)
    }

    /// SidebarRows passes the store change's cause: each cause gets its own flush, and the person
    /// flush maps only the rows a person's change marked, not the ones automation marked.
    @Test func theRowFeedFlushesPersonRowsApartFromAutomationRows() {
        let causes = ObservationCauses()
        let titles = RowTitles()
        let scheduled = ScheduledFlushes()
        let feed = SidebarRowFeed(cause: { causes.currentCause }, schedule: { cause, work in scheduled.flushes.append((cause: cause, work: work)) })
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
