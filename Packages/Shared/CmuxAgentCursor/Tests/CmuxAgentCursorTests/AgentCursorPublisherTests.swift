import Testing
@testable import CmuxAgentCursor

@MainActor
private final class RecordingRenderer: AgentCursorRendering {
    var rendered: [AutomationInputEvent] = []
    func render(_ event: AutomationInputEvent) { rendered.append(event) }
}

private func event(_ session: String, _ seq: UInt64) -> AutomationInputEvent {
    AutomationInputEvent(sessionID: session, targetID: "tab_1", seq: seq, kind: .click, space: .viewport,
                         point: .init(x: 1, y: 2), tMs: Double(seq))
}

@MainActor
@Suite struct AgentCursorPublisherTests {
    @Test func forwardsEventsInSeqOrderPerSession() {
        let renderer = RecordingRenderer()
        let publisher = AgentCursorPublisher(renderer: renderer)
        publisher.publish(event("a", 0))
        publisher.publish(event("b", 0))
        publisher.publish(event("a", 1))
        #expect(renderer.rendered.map { "\($0.sessionID)\($0.seq)" } == ["a0", "b0", "a1"])
    }

    @Test func dropsReplayedAndReorderedFrames() {
        let renderer = RecordingRenderer()
        let publisher = AgentCursorPublisher(renderer: renderer)
        publisher.publish(event("a", 3))
        publisher.publish(event("a", 3))
        publisher.publish(event("a", 2))
        publisher.publish(event("a", 5))
        #expect(renderer.rendered.map(\.seq) == [3, 5], "a gap is drawn; a replay or an older frame is not")
    }

    @Test func aSessionCanStartOverAfterItEnds() {
        let renderer = RecordingRenderer()
        let publisher = AgentCursorPublisher(renderer: renderer)
        publisher.publish(event("a", 4))
        publisher.endSession("a")
        publisher.publish(event("a", 0))
        #expect(renderer.rendered.map(\.seq) == [4, 0])
    }
}
