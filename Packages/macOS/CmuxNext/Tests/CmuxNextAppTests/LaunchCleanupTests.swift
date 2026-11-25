@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch cleanup runs each of its jobs once the launch settles, the Phone Access leftovers
/// (`PhoneAccessLeftovers`, #42780) after the download temp files.
@MainActor
@Suite struct LaunchCleanupTests {
    @Test func thePhoneAccessLeftoversRunAfterTheLaunchSettles() {
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let settle = LaunchSettle(reveal: LaunchReveal(deadline: .seconds(60)), firstFrame: firstFrame,
                                  imageHold: LaunchImageHold())
        var ran: [String] = []
        #expect(LaunchCleanup().jobs.count == 2, "the download temp files and the Phone Access leftovers")
        LaunchCleanup(jobs: [{ ran.append("downloads") }, { ran.append("phone access") }]).schedule(on: settle)
        #expect(ran.isEmpty)
        settle.settle()
        firstFrame.open()
        #expect(ran == ["downloads", "phone access"])
    }
}
