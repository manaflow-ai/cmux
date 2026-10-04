import CmuxAgentCursor
import QuartzCore
import Testing
@testable import CmuxNextAgentCursor

@MainActor
private final class OneVisibleTab: AgentCursorTargetResolving {
    func placement(forTarget targetID: String) -> AgentCursorPlacement {
        targetID == "tab_1" ? .visible(content: CGRect(x: 0, y: 0, width: 400, height: 300), magnification: 1) : .elsewhere
    }
}

private func click(_ seq: UInt64, target: String = "tab_1") -> AutomationInputEvent {
    AutomationInputEvent(sessionID: "s1", targetID: target, seq: seq, kind: .click, space: .viewport,
                         point: .init(x: 20, y: 30), tMs: Double(seq))
}

@MainActor
@Suite struct AgentCursorStackTests {
    @Test func aWiredStackWithNoEventsHasNoLayersAndNoAnimations() {
        let plane = CALayer()
        _ = AgentCursorStack(hostLayer: plane)
        #expect(plane.sublayers == nil)
        #expect(plane.animationKeys() == nil)
    }

    @Test func eventsBeforeTheResolverExistsDrawNothing() {
        let plane = CALayer()
        let stack = AgentCursorStack(hostLayer: plane)
        stack.publisher.publish(click(0))
        stack.publisher.publish(click(1))
        #expect(plane.sublayers == nil)
        #expect(stack.host.cursorLayer(for: "s1") == nil)
    }

    @Test func settingTheResolverLaterDrawsWithoutOtherChanges() throws {
        let plane = CALayer()
        let stack = AgentCursorStack(hostLayer: plane)
        stack.publisher.publish(click(0))
        stack.resolver.inner = OneVisibleTab()
        stack.publisher.publish(click(1))
        #expect(plane.sublayers?.count == 1)
        let cursor = try #require(stack.host.cursorLayer(for: "s1"))
        #expect(cursor.root.position == CGPoint(x: 20, y: 30))
    }
}
