import CmuxNextControl
import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
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
