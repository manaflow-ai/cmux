import CmuxAgentCursor
import QuartzCore
import Testing
@testable import CmuxNextAgentCursor

@MainActor
@Suite struct AgentCursorLayerHostTests {
    private func makeHost() -> (CALayer, AgentCursorLayerHost) {
        let plane = CALayer()
        plane.isGeometryFlipped = true
        let host = AgentCursorLayerHost(hostLayer: plane) { _ in CGColor(gray: 0.9, alpha: 1) }
        return (plane, host)
    }

    @Test func placeAddsOneCursorLayerPerSessionAtThePoint() throws {
        let (plane, host) = makeHost()
        host.apply(.place(session: "a", point: CGPoint(x: 120, y: 80)))
        host.apply(.place(session: "b", point: CGPoint(x: 10, y: 10)))
        host.apply(.place(session: "a", point: CGPoint(x: 130, y: 90)))
        #expect(plane.sublayers?.count == 2)
        let a = try #require(host.cursorLayer(for: "a"))
        #expect(a.root.position == CGPoint(x: 130, y: 90))
        #expect(a.root.isHidden == false)
    }

    @Test func glideAddsOneKeyframeAnimationAndLandsTheModelValueOnTheTarget() throws {
        let (_, host) = makeHost()
        host.apply(.place(session: "a", point: CGPoint(x: 0, y: 0)))
        let plan = GlideMotion().plan(fromX: 0, fromY: 0, toX: 300, toY: 40, endHeading: AgentCursorOverlayModel.restingHeading)
        host.apply(.glide(session: "a", plan: plan))
        let cursor = try #require(host.cursorLayer(for: "a"))
        #expect(cursor.root.position == CGPoint(x: 300, y: 40))
        let glide = try #require(cursor.root.animation(forKey: "agentCursor.glide") as? CAKeyframeAnimation)
        #expect(glide.keyPath == "position")
        #expect(abs(glide.duration - plan.duration) < 1e-9)
        #expect(cursor.root.animation(forKey: "agentCursor.heading") != nil)
        #expect(cursor.root.animationKeys()?.count == 2, "travel is the only animation: no timers, no per-frame work")
    }

    @Test func pulseAnimatesTheRippleOnly() throws {
        let (_, host) = makeHost()
        host.apply(.place(session: "a", point: .zero))
        host.apply(.pulse(session: "a"))
        let cursor = try #require(host.cursorLayer(for: "a"))
        #expect(cursor.ripple.animation(forKey: "agentCursor.pulse") != nil)
        #expect(cursor.root.animationKeys() == nil)
    }

    @Test func indicateShowsTheDotAtTheAnchorAndHidesTheArrow() throws {
        let (_, host) = makeHost()
        host.apply(.indicate(session: "a", anchor: CGPoint(x: 70, y: 14)))
        let cursor = try #require(host.cursorLayer(for: "a"))
        #expect(cursor.root.position == CGPoint(x: 70, y: 14))
        #expect(cursor.indicator.isHidden == false)
        #expect(cursor.arrow.isHidden == true)
        host.apply(.place(session: "a", point: CGPoint(x: 5, y: 5)))
        #expect(cursor.indicator.isHidden == true)
        #expect(cursor.arrow.isHidden == false)
    }

    @Test func pausedCursorsAreOutlinesAndRemoveDropsTheLayer() throws {
        let (plane, host) = makeHost()
        host.apply(.place(session: "a", point: .zero))
        host.apply(.setPaused(session: "a", paused: true))
        let cursor = try #require(host.cursorLayer(for: "a"))
        #expect(cursor.arrow.fillColor == nil)
        #expect(cursor.arrow.strokeColor != nil)
        host.apply(.setPaused(session: "a", paused: false))
        #expect(cursor.arrow.fillColor != nil)
        host.apply(.hide(session: "a"))
        #expect(cursor.root.isHidden)
        host.apply(.remove(session: "a"))
        #expect(host.cursorLayer(for: "a") == nil)
        #expect(plane.sublayers?.isEmpty ?? true)
    }
}
