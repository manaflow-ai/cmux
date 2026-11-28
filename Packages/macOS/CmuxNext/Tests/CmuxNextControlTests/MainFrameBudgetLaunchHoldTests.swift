@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// The launch hold on the budget's background class (CMUX-629): background work waits until the launch settles,
/// is never dropped, and runs in order once the hold is released. Split from `MainFrameBudgetTests` to keep that
/// file under its size ceiling.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainFrameBudgetLaunchHoldTests {
    /// CMUX-629 (Leo: "technically only need to draw that one workspace open and the sidebar"): at launch the next
    /// Cmd-N's workspace (`WorkspaceSpareSlot`, its panes and terminal) and the other spares are background work, and
    /// they ran in the first on-time frames, while the open workspace was still coming in. Under the launch hold no
    /// background task runs, in on-time frames or past the idle timeout; the other classes run as before; the
    /// release lets the queued work run from the next frame, with nothing dropped.
    @Test func theLaunchHoldKeepsBackgroundWorkQueuedUntilItsRelease() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.holdBackgroundForLaunch()
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        let spare = FrameBatchQueue(owner: "WorkspaceSpare", budgeted: .background, on: scheduler)
        let rows = FrameBatchQueue(owner: "SidebarRows", budgeted: .visible, on: scheduler)
        let agents = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: scheduler)
        var steps: [String] = [], time = 10.0
        let shown = Box(0), asked = Box(0)
        func frame() {
            rows.enqueue { shown.withLock { $0 += 1 } }
            agents.enqueue { asked.withLock { $0 += 1 } }
            clock.advance(ms: 16.7)
            time += 0.0167
            scheduler.frameDidFire(timestamp: time, refreshInterval: 1.0 / 60)
        }
        spare.enqueue {
            steps.append("reserve")
            spare.enqueue { steps.append("build") }
        }
        // 30 on-time frames: half a second, past the 300 ms idle timeout.
        for _ in 0..<30 { frame() }
        #expect(steps.isEmpty, "background work ran under the launch hold: \(steps)")
        #expect(shown.withLock { $0 } == 30, "visible work waited under the launch hold")
        #expect(asked.withLock { $0 } == 30, "automation work waited under the launch hold")
        #expect(budget.stats.heldForLaunch > 0)
        budget.releaseLaunchHold()
        frame()
        #expect(steps == ["reserve"], "the release did not let the queued background work run")
        frame()
        #expect(steps == ["reserve", "build"])
    }

    /// The hold delays and never drops: every task two background owners queued under it runs after the release, each
    /// owner's in the order it was queued.
    @Test func everyTaskQueuedUnderTheLaunchHoldRunsAfterItsReleaseInOrder() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.holdBackgroundForLaunch()
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in FakeFrameLink() }
        let spare = FrameBatchQueue(owner: "WorkspaceSpare", budgeted: .background, on: scheduler)
        let warm = FrameBatchQueue(owner: "KeyBindings.warm", budgeted: .background, on: scheduler)
        var ran: [String] = [], time = 10.0
        for index in 0..<5 {
            spare.enqueue { clock.advance(ms: 3); ran.append("spare \(index)") }
            warm.enqueue { clock.advance(ms: 3); ran.append("warm \(index)") }
        }
        func frame() {
            clock.advance(ms: 16.7)
            time += 0.0167
            scheduler.frameDidFire(timestamp: time, refreshInterval: 1.0 / 60)
        }
        for _ in 0..<10 { frame() }
        #expect(ran.isEmpty)
        budget.releaseLaunchHold()
        for _ in 0..<40 where ran.count < 10 { frame() }
        #expect(ran.count == 10, "tasks queued under the hold were dropped: \(ran)")
        #expect(ran.filter { $0.hasPrefix("spare") } == (0..<5).map { "spare \($0)" })
        #expect(ran.filter { $0.hasPrefix("warm") } == (0..<5).map { "warm \($0)" })
    }

    /// The hold is only the launch's: a budget that was never held runs background work in an on-time frame, and a
    /// second release changes nothing.
    @Test func aBudgetWithNoLaunchHoldRunsBackgroundWork() {
        let clock = BudgetClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.background))
        budget.holdBackgroundForLaunch()
        #expect(!budget.mayRun(.background))
        budget.releaseLaunchHold()
        budget.releaseLaunchHold()
        #expect(budget.mayRun(.background))
        #expect(!budget.holdsBackgroundForLaunch)
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class BudgetClock {
    private var now: UInt64 = 1_000_000_000
    // Strong: a scheduler's stall timer can fire after its test returned and read the clock through the budget.
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(ms: Double) { now += UInt64(ms * 1_000_000) }
}

@MainActor
private final class FakeFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

private final class Box<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    nonisolated deinit {}
    func withLock<R>(_ body: (inout sending Value) -> sending R) -> sending R { mutex.withLock(body) }
}
