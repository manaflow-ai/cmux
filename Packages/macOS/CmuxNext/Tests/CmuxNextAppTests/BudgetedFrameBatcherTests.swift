@testable import CmuxNextApp
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

    // MARK: No batcher outside the budget window (p06-scheduler-010)

    /// A SidebarRows flush no input of the person's caused is budgeted visible work: it waits while
    /// a key is pending, one frame and never two.
    @Test func anAutomationRowFlushYieldsToPendingInput() {
        let (work, input, clock) = Self.budgetedScheduler()
        let rows = FrameBatcher(owner: "SidebarRows", budgeted: .visible, on: work)
        let log = RunLog()
        rows.scheduleFrame(byPerson: false) { log.automation += 1 }
        input.pending = true
        Self.fire(work, clock, frame: 1)
        #expect(log.automation == 0, "the flush ran while a key was pending")
        Self.fire(work, clock, frame: 2)
        #expect(log.automation == 1, "the flush was held a second frame")
    }

    /// Cmd-N's row patch is the person's: it runs in the next frame, ahead of the budgeted classes and
    /// while a key is pending, though 400 automation patches are queued before it; those spread out.
    @Test func aPersonsRowPatchRunsInTheNextFrameWhile400AutomationPatchesWait() {
        let (work, input, clock) = Self.budgetedScheduler()
        let rows = FrameBatcher(owner: "SidebarRows", budgeted: .visible, on: work)
        let log = RunLog()
        for _ in 0..<400 {
            rows.scheduleFrame(byPerson: false) {
                log.automation += 1
                clock.advance(ms: 1)
            }
        }
        rows.scheduleFrame(byPerson: true) { log.personRanAfter = log.automation }
        input.pending = true
        Self.fire(work, clock, frame: 1)
        #expect(log.personRanAfter == 0, "the person's patch waited behind automation (\(String(describing: log.personRanAfter)))")
        #expect(log.automation == 0, "automation patches ran while a key was pending")
        #expect(rows.personCount == 0)
        input.pending = false
        for frame in 2...4 { Self.fire(work, clock, frame: frame) }
        #expect(log.automation > 0, "the automation patches never ran")
        #expect(log.automation <= 3 * 8, "the automation patches were not spread out (\(log.automation) in 3 frames)")
        #expect(rows.queue.count == 400 - log.automation)
    }

    /// The feed's flushes coalesce: 400 rows an agent changed wait in one flush held by a pending key.
    /// The row Cmd-N changed, marked in the person's turn, does not join that held flush: it flushes
    /// in the next frame (the held flush then finds it done).
    @Test func aPersonsRowChangeIsNotHeldBehindAQueuedAutomationFlush() {
        let (work, input, clock) = Self.budgetedScheduler()
        let turn = PersonTurnFlag()
        let frames = FrameBatcher(owner: "SidebarRows", budgeted: .visible, on: work)
        let feed = SidebarRowFeed(schedule: { frames.scheduleFrame(byPerson: false, $0) },
                                  urgent: (isNow: { turn.isPerson }, schedule: { frames.scheduleFrame(byPerson: true, $0) }))
        let statuses = (0...400).map { _ in RowStatus() }
        let patched = PatchLog()
        feed.onChange = { rows in patched.ids.formUnion(rows.map(\.id)) }
        feed.beginPass(inputs: 0)
        for (index, status) in statuses.enumerated() {
            let id = WorkspaceID("w\(index)")
            _ = feed.row(id, machine: .local) { SidebarWorkspace(id: id, machineID: .local, title: "w", status: status.text) }
        }
        _ = feed.fill([])
        for status in statuses.dropLast() { status.text = "agent" }
        turn.isPerson = true
        statuses[400].text = "new"
        turn.isPerson = false
        input.pending = true
        Self.fire(work, clock, frame: 1)
        #expect(patched.ids.contains(WorkspaceID("w400")), "the person's row waited behind the held automation flush")
        #expect(patched.ids.count == 401, "the urgent flush maps every dirty row it finds (\(patched.ids.count))")
        #expect(frames.queue.count == 1, "the automation flush is still held")
        Self.fire(work, clock, frame: 2)
        #expect(frames.queue.count == 0)
        #expect(patched.ids.count == 401)
    }

    /// A pane selection no input of the person's caused (a CLI or daemon change) is budgeted visible
    /// work: held one frame by a pending key.
    @Test func aSelectionNoInputCausedWaitsOneFrameForAPendingKey() {
        let (work, input, clock) = Self.budgetedScheduler()
        let presentation = ContentPresentationScheduler(frames: FrameBatcher(owner: "ContentPresentation", budgeted: .visible, on: work),
                                                        isPersonTurn: { false })
        let pane = PresentedPane()
        presentation.setNeedsShowSelected(pane)
        input.pending = true
        Self.fire(work, clock, frame: 1)
        #expect(pane.shown == 0, "the selection showed while a key was pending")
        Self.fire(work, clock, frame: 2)
        #expect(pane.shown == 1)
    }

    /// A selection a person's key changed shows in the next frame though a key is pending, and takes
    /// the selections queued before it along: each pane shows once (the budgeted drain it supersedes
    /// does nothing).
    @Test func aSelectionAPersonsKeyChangedShowsInTheNextFrame() {
        let (work, input, clock) = Self.budgetedScheduler()
        let turn = PersonTurnFlag()
        let presentation = ContentPresentationScheduler(frames: FrameBatcher(owner: "ContentPresentation", budgeted: .visible, on: work),
                                                        isPersonTurn: { turn.isPerson })
        let automation = PresentedPane(), person = PresentedPane()
        presentation.setNeedsShowSelected(automation)
        turn.isPerson = true
        presentation.setNeedsShowSelected(person)
        turn.isPerson = false
        input.pending = true
        Self.fire(work, clock, frame: 1)
        #expect(person.shown == 1, "the person's selection waited for the budget")
        #expect(automation.shown == 1)
        Self.fire(work, clock, frame: 2)
        #expect(person.shown == 1 && automation.shown == 1, "a superseded drain showed a pane again")
    }

    /// A scheduler on a fake link whose budget reads the test's clock and pending-input flag.
    private static func budgetedScheduler() -> (MainWorkScheduler, PendingKeys, BatcherBudgetClock) {
        let clock = BatcherBudgetClock(), input = PendingKeys()
        let budget = MainFrameBudget(input: input, uptimeNanos: clock.read)
        return (MainWorkScheduler.testing(budget: budget, clock: ManualClock()) { _ in CountedLink() }, input, clock)
    }

    /// One display frame, 17 ms after the last.
    private static func fire(_ work: MainWorkScheduler, _ clock: BatcherBudgetClock, frame: Int) {
        clock.advance(ms: 17)
        work.frameDidFire(timestamp: Double(frame), refreshInterval: 1.0 / 60)
    }
}

/// What the batches ran.
@MainActor
private final class RunLog {
    var automation = 0
    /// How many automation patches had run when the person's ran; nil until it ran.
    var personRanAfter: Int?
}

/// A row's observed status, as a store holds it.
@MainActor @Observable
private final class RowStatus {
    var text = "idle"
}

/// The ids of the rows the feed patched.
@MainActor
private final class PatchLog {
    var ids: Set<WorkspaceID> = []
}

/// Whether the test's dispatch is a person's discrete input.
@MainActor
private final class PersonTurnFlag {
    var isPerson = false
}

/// A pane whose selection is alive (no surface to create); counts its shows.
@MainActor
private final class PresentedPane: PresentablePane {
    private(set) var shown = 0
    var selectedContentIsAlive: Bool { true }
    func showSelected() { shown += 1 }
}

/// A person's key waiting for the main thread, as the test sets it.
@MainActor
private final class PendingKeys: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
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
