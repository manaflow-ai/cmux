@testable import CmuxNextPages
import CmuxNextWakeupsTestSupport
import Testing

/// A hung agent-chat renderer is ended by itself (#45888): every chat shares it, so until a person
/// restarted it from App Health, no chat took a click and every new chat fell back to WebKit.
@MainActor
struct AgentRendererHangRestartTests {
    private final class Rig {
        let clock = ManualClock()
        var restarts = 0
        var allowed = true
        lazy var policy = AgentRendererHangRestart(clock: clock, limit: .seconds(5), mayRestart: { [unowned self] in allowed },
                                                   restart: { [unowned self] in restarts += 1 })

        /// Lets the timer's hop to the main actor run.
        func settle() async { for _ in 0..<50 { await Task.yield() } }
    }

    @Test func aRendererThatStaysHungIsRestartedOnceTheLimitPasses() async throws {
        let rig = Rig()
        rig.policy.rendererChanged(unresponsive: true)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .seconds(4))
        await rig.settle()
        #expect(rig.restarts == 0)
        rig.clock.advance(by: .seconds(1))
        await rig.settle()
        #expect(rig.restarts == 1)
        #expect(!rig.policy.isPending)
    }

    @Test func aRendererThatAnswersAgainBeforeTheLimitIsKept() async throws {
        let rig = Rig()
        rig.policy.rendererChanged(unresponsive: true)
        try await rig.clock.waitForSleeper()
        rig.policy.rendererChanged(unresponsive: false)
        rig.clock.advance(by: .seconds(10))
        await rig.settle()
        #expect(rig.restarts == 0)
        #expect(!rig.policy.isPending)
    }

    @Test func repeatedHangReportsDoNotPushTheRestartBack() async throws {
        let rig = Rig()
        rig.policy.rendererChanged(unresponsive: true)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .seconds(3))
        rig.policy.rendererChanged(unresponsive: true)
        rig.clock.advance(by: .seconds(2))
        await rig.settle()
        #expect(rig.restarts == 1)
    }

    @Test func noRestartOverUnsavedEditsOrAfterTheSessionEnded() async throws {
        let rig = Rig()
        rig.allowed = false
        rig.policy.rendererChanged(unresponsive: true)
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: .seconds(5))
        await rig.settle()
        #expect(rig.restarts == 0)

        let ended = Rig()
        ended.policy.rendererChanged(unresponsive: true)
        try await ended.clock.waitForSleeper()
        ended.policy.cancel()
        ended.clock.advance(by: .seconds(5))
        await ended.settle()
        #expect(ended.restarts == 0)
    }
}
