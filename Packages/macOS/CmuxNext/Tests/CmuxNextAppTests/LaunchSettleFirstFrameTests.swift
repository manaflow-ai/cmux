@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// REOPEN-F7 (reopen marks, feat 3160789, Cmd-Q keep + reopen, 10 cycles): in the 3 cycles whose Home page pane was
/// presented before any terminal, the first window frame came 33 ms later (296-300 ms after main, against 253-264 ms).
/// A page shown first makes the launch's pane region ready inside applicationDidFinishLaunching, and the launch settled
/// there: the deferred warm-ups (palette, open panel, cleanup, settings migrations, control socket) ran before the first
/// window frame. The launch may settle that early; its deferred work still waits for the first window frame.
@MainActor
@Suite struct LaunchSettleFirstFrameTests {
    private static func gate() -> FirstFrameGate {
        FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
    }

    /// Its own image hold: another suite's launch image on the shared one must not hold this suite's work.
    private static func settle(_ firstFrame: FirstFrameGate) -> LaunchSettle {
        LaunchSettle(reveal: LaunchReveal(deadline: .seconds(60)), firstFrame: firstFrame, imageHold: LaunchImageHold())
    }

    @Test func aSettleBeforeTheFirstWindowFrameRunsItsWorkAfterThatFrame() {
        let firstFrame = Self.gate()
        let settle = Self.settle(firstFrame)
        var ran: [String] = []
        settle.whenSettled { ran.append("palette") }
        settle.settle() // a page pane shown first, inside applicationDidFinishLaunching
        settle.whenSettled { ran.append("open panel") }
        #expect(ran.isEmpty, "the launch's deferred work ran before the first window frame")
        #expect(!settle.isSettled)
        firstFrame.open()
        #expect(ran == ["palette", "open panel"])
        #expect(settle.isSettled)
        settle.whenSettled { ran.append("late") }
        #expect(ran == ["palette", "open panel", "late"])
    }

    @Test func aSettleAfterTheFirstWindowFrameRunsItsWorkAtOnce() {
        let firstFrame = Self.gate()
        let settle = Self.settle(firstFrame)
        var ran = 0
        settle.whenSettled { ran += 1 }
        firstFrame.open()
        #expect(ran == 0, "the first window frame alone is no settle")
        settle.settle() // the first live terminal frame
        settle.settle()
        #expect(ran == 1)
    }

    @Test func theSettledWaitReturnsOnlyAfterTheFirstWindowFrame() async {
        let firstFrame = Self.gate()
        let settle = Self.settle(firstFrame)
        settle.settle()
        var returned = false
        let waiter = Task { @MainActor in
            await settle.settled(within: .seconds(60))
            returned = true
        }
        // No signal says "has not returned": 20 turns are far more than the wait needs to return when it may.
        for _ in 0..<20 { await Task.yield() }
        #expect(!returned, "the control socket and settings migrations started before the first window frame")
        firstFrame.open()
        await waiter.value
        #expect(returned)
    }
}
