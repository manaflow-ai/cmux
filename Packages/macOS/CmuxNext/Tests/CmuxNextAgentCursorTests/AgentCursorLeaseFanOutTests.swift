import CmuxAgentCursor
import QuartzCore
import Testing
@testable import CmuxNextAgentCursor

@MainActor
private final class Visible: AgentCursorTargetResolving {
    func placement(forTarget targetID: String) -> AgentCursorPlacement {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        return .visible(content: rect, clip: rect, zoom: 1, magnification: 1)
    }
}

@MainActor
@Suite struct AgentCursorLeaseFanOutTests {
    private func click(_ seq: UInt64) -> AutomationInputEvent {
        AutomationInputEvent(sessionID: "s1", targetID: "t1", seq: seq, kind: .click, space: .viewport,
                             point: .init(x: 20, y: 30), tMs: Double(seq))
    }

    @Test func aClosedTabRemovesTheCursorInEveryContent() {
        let shown = CALayer(), parked = CALayer()
        let a = AgentCursorStack(hostLayer: shown, resolver: Visible())
        let b = AgentCursorStack(hostLayer: parked, resolver: Visible())
        let fanOut = AgentCursorLeaseFanOut(models: { [a.model, b.model] })
        fanOut.leaseChanged(target: "t1", session: "s1", wireState: "driving")
        a.publisher.publish(click(0))
        #expect(shown.sublayers?.count == 1)
        fanOut.leaseChanged(target: "t1", session: nil, wireState: nil)
        #expect(shown.sublayers?.isEmpty ?? true, "the closed tab's cursor is gone")
        #expect(parked.sublayers?.isEmpty ?? true)
    }

    @Test func aPausedLeaseOutlinesTheCursorAndHandBackFillsIt() throws {
        let plane = CALayer()
        let stack = AgentCursorStack(hostLayer: plane, resolver: Visible())
        let fanOut = AgentCursorLeaseFanOut(models: { [stack.model] })
        fanOut.leaseChanged(target: "t1", session: "s1", wireState: "driving")
        stack.publisher.publish(click(0))
        let cursor = try #require(stack.host.cursorLayer(for: "s1"))
        fanOut.leaseChanged(target: "t1", session: "s1", wireState: "paused")
        #expect(cursor.arrow.fillColor == nil)
        fanOut.leaseChanged(target: "t1", session: "s1", wireState: "driving")
        #expect(cursor.arrow.fillColor != nil)
    }
}
