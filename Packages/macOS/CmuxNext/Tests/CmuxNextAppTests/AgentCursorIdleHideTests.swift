import CmuxNextAgentCursor
import QuartzCore
import Testing

/// An in-app agent cursor hides 10 s after its agent's last action, as the
/// cmux-cua screen cursor does (cx-ujus, agent-cursor.md idle hide): one
/// opacity animation with a begin time, armed again by every action.
@MainActor
struct AgentCursorIdleHideTests {
    @Test func aCursorFadesTenSecondsAfterItsLastAction() throws {
        let host = AgentCursorLayerHost(hostLayer: CALayer(), color: { _ in CGColor(gray: 1, alpha: 1) })
        host.apply(.place(session: "s", point: CGPoint(x: 10, y: 10)))
        let root = try #require(host.cursorLayer(for: "s")).root
        let fade = try #require(root.animation(forKey: "agentCursor.idleHide") as? CABasicAnimation)
        #expect((fade.toValue as? NSNumber)?.doubleValue == 0)
        #expect(fade.isRemovedOnCompletion == false, "the cursor stays hidden after the fade")
        let delay = fade.beginTime - root.convertTime(CACurrentMediaTime(), from: nil)
        #expect(delay > 9 && delay <= AgentCursorLayerHost.idleHideDelay)

        host.apply(.indicate(session: "s", anchor: .zero))
        let again = try #require(root.animation(forKey: "agentCursor.idleHide") as? CABasicAnimation)
        #expect(again.beginTime >= fade.beginTime, "a new action restarts the wait")
    }
}
