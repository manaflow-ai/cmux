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
        // The saved copy's paint (`copy: true`) is not the live chat: the steps wait on.
        timings.mark("agent_pane.painted")
        for _ in 0..<20 { await Task.yield() }
        #expect(!gate.isOpen, "the saved copy's paint")
        timings.mark("agent_pane.page_painted")
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
        #expect(ran == ["history"])
    }

    @Test func aNewTabFrontOpensAtItsPaint() async {
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let timings = AgentPaneLaunchTimings()
        let gate = FrontChatPaintGate.make(after: firstFrame, timings: timings, timer: DemandTimer(owner: "test", clock: ManualClock()))
        firstFrame.open()
        timings.mark("agent_pane.newtab_painted")
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
    }

    /// cmux#58024's bench: a New Tab page restored behind the front chat painted at ~1350 ms and opened the gate
    /// before the live front chat drew (~1570 ms). With the front a chat, only the chat's live paint opens it.
    @Test func aBackgroundNewTabPaintLeavesAChatFrontsGateShut() async {
        let firstFrame = FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
        let timings = AgentPaneLaunchTimings()
        let gate = FrontChatPaintGate.make(after: firstFrame, timings: timings, timer: DemandTimer(owner: "test", clock: ManualClock()))
        firstFrame.open()
        timings.mark("launch.front_chat_shown")
        timings.mark("agent_pane.newtab_painted")
        for _ in 0..<50 { await Task.yield() }
        #expect(!gate.isOpen, "a New Tab page that is not the front")
        timings.mark("agent_pane.page_painted")
        for _ in 0..<50 where !gate.isOpen { await Task.yield() }
        #expect(gate.isOpen)
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
