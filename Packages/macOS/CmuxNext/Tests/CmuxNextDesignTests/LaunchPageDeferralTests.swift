import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// No page view before the first window frame (startup-tti).
@MainActor
@Suite struct LaunchPageDeferralTests {
    private func gate() -> FirstFrameGate { FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock())) }

    @Test func pagesWaitForTheFirstFrameThenShowOnceInOrder() {
        let frame = gate(), pages = LaunchPageDeferral()
        var shown: [String] = [], marks: [String] = []
        pages.bind(frame) { marks.append($0) }
        #expect(pages.defers("p1/chat") { shown.append("chat") })
        #expect(pages.defers("p2/browser") { shown.append("browser") })
        #expect(pages.defers("p1/chat") { shown.append("chat again") }, "a second ask still waits, and shows once")
        #expect(shown.isEmpty)
        #expect(marks == ["pages.deferred_until_frame"])
        frame.open()
        #expect(shown == ["chat", "browser"])
        #expect(marks == ["pages.deferred_until_frame", "pages.created"])
        #expect(!pages.defers("p3/page") { shown.append("late") }, "after the frame a page is made at once")
        #expect(shown == ["chat", "browser"])
    }

    @Test func unboundItDefersNothing() {
        let pages = LaunchPageDeferral()
        #expect(!pages.defers("p1/chat") {})
    }

    @Test func aFrameThatAlreadyCommittedDefersNothing() {
        let frame = gate(), pages = LaunchPageDeferral()
        frame.open()
        pages.bind(frame) { _ in }
        #expect(!pages.defers("p1/chat") {})
    }
}
