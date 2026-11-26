@testable import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The launch steps no chat needs wait for the front chat's first paint, or the backstop (research:startup:2026-11-25).
@MainActor
@Suite struct FrontChatPaintGateTests {
    @Test func opensAtTheFrontChatsPaintNotAtOtherMarksNorBeforeTheFirstFrame() async {
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let timings = AgentPaneLaunchTimings()
        let gate = FrontChatPaintGate.make(after: firstFrame, timings: timings, timer: DemandTimer(owner: "test", clock: ManualClock()))
        var ran: [String] = []
        gate.whenOpen { ran.append("history") }
        timings.mark("agent_pane.transport_open")
        for _ in 0..<20 { await Task.yield() }
        #expect(!gate.isOpen, "another chat mark")
        firstFrame.open()
        timings.mark("agent_pane.painted")
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
        #expect(ran == ["history"])
    }

    @Test func aFrontThatDrawsNoChatOpensAtTheBackstopAfterTheFirstFrame() async throws {
        let clock = ManualClock()
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let gate = FrontChatPaintGate.make(after: firstFrame, backstop: .milliseconds(1500), timings: AgentPaneLaunchTimings(),
                                           timer: DemandTimer(owner: "test", clock: clock))
        firstFrame.open()
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1499))
        for _ in 0..<20 { await Task.yield() }
        #expect(!gate.isOpen)
        clock.advance(by: .milliseconds(1))
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
    }
}
