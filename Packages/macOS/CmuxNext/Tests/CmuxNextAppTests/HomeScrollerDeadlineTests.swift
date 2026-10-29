@testable import CmuxNextHome
@testable import CmuxNextWakeups
import Testing

/// The Home transcript's scroller deadlines (fade-in, widen, hide) are visible-class MainDeadlines on the
/// app's deadline scheduler, not run-loop timers of their own: the fade-in is precise,
/// the others flexible, a new schedule replaces the pending one, a cancel drops its wake, and an action
/// runs once from the queue's fire.
@MainActor @Suite(.serialized) struct HomeScrollerDeadlineTests {
    private final class Count { var n = 0 }

    @Test func theFadeInIsPreciseAndTheOthersFlexibleVisibleDeadlines() throws {
        let rig = MainDeadlineRig()
        let wake = HomeDemandWake(node: VisibilityNode(root: "test.home.scroller", own: .visible), deadlines: rig.deadlines)
        let show = try #require(wake.makeDeadline(owner: "Home.scroller.show", exact: true) as? HomeViewDeadline)
        let hide = try #require(wake.makeDeadline(owner: "Home.scroller.hide", exact: false) as? HomeViewDeadline)
        guard case .precise = show.deadline.alignment else { Issue.record("the fade-in is not precise"); return }
        guard case .flexible = hide.deadline.alignment else { Issue.record("the hide is not flexible"); return }
        #expect(show.deadline.workClass == .visible && hide.deadline.workClass == .visible)
        #expect(show.deadline.owner == "Home.scroller.show" && hide.deadline.owner == "Home.scroller.hide")
    }

    @Test func aScrollerDeadlineRunsOnceFromTheQueueAndACancelDropsItsWake() {
        let rig = MainDeadlineRig()
        let wake = HomeDemandWake(node: VisibilityNode(root: "test.home.scroller", own: .visible), deadlines: rig.deadlines)
        let deadline = wake.makeDeadline(owner: "Home.scroller.hide", exact: false)
        let fired = Count()

        deadline.schedule(after: 5) { fired.n += 10 }
        deadline.schedule(after: 0.845) { fired.n += 1 }
        #expect(deadline.isPending)
        #expect(rig.hasArmedWake)
        rig.fireAndRun()
        #expect(fired.n == 1, "only the replacing deadline runs")
        #expect(!deadline.isPending)
        #expect(!rig.hasArmedWake, "nothing re-arms itself")

        deadline.schedule(after: 0.075) { fired.n += 1 }
        deadline.cancel()
        #expect(!deadline.isPending)
        #expect(!rig.hasArmedWake)
        rig.frame()
        #expect(fired.n == 1)
    }
}
