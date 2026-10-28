import CmuxNextAgentCursor
import CmuxNextDesign
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

    /// Its fade takes the motion settings (cx-yt7ya): a literal 0.3 s ran at every animation speed
    /// and past the Reduce Motion ceiling.
    @Test func theIdleFadeKeepsToReduceMotionsCeiling() throws {
        let host = AgentCursorLayerHost(hostLayer: CALayer(), color: { _ in CGColor(gray: 1, alpha: 1) })
        // Synchronous: the override is process-wide.
        let (duration, ceiling) = try { () throws -> (CFTimeInterval, TimeInterval) in
            Motion.reduceMotionOverride = true
            defer { Motion.reduceMotionOverride = nil }
            host.apply(.place(session: "s", point: CGPoint(x: 10, y: 10)))
            let root = try #require(host.cursorLayer(for: "s")).root
            let fade = try #require(root.animation(forKey: "agentCursor.idleHide") as? CABasicAnimation)
            return (fade.duration, Motion.cursor.duration(.crossfade))
        }()
        #expect(duration <= ceiling)
    }
}
