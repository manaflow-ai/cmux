import AppKit
import QuartzCore
import Testing
@testable import CmuxNextDesign

/// The launch mark: the cmux chevron drawn natively, invisible until it
/// resolves in, with no overshoot, and a plain fade under Reduce Motion.
/// Reduce Motion is pinned both ways: CI runners have it on, the capture
/// minis off.
@MainActor
@Suite(.serialized)
struct LaunchMarkTests {
    @Test func pathIsTheChevronFittedAndCentered() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 36)
        let box = CGPath.launchMark(in: rect).boundingBoxOfPath
        #expect(abs(box.height - 36) < 0.001)
        #expect(abs(box.width - 36 * CGPath.launchMarkAspect) < 0.001)
        #expect(abs(box.midX - rect.midX) < 0.001)
        #expect(abs(box.midY - rect.midY) < 0.001)
    }

    private func make() -> LaunchMarkView {
        let view = LaunchMarkView(frame: NSRect(origin: .zero, size: LaunchMarkView(frame: .zero).intrinsicContentSize))
        view.layout()
        return view
    }

    @Test func markIsInvisibleUntilRevealed() {
        let view = make()
        #expect(!view.isRevealed)
        #expect(view.revealedStyle == nil)
        #expect(view.mark.animationKeys() == nil)
    }

    @Test(arguments: [false, true])
    func traceDrawsTheOutlineThenFills(reduceMotion: Bool) throws {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = reduceMotion
        let view = make()
        view.reveal(.trace)
        #expect(view.isRevealed && view.outline.strokeEnd == 1 && view.body.opacity == 1)
        if reduceMotion {
            #expect(view.mark.animationKeys() == ["launch.opacity"])
            #expect(view.outline.animationKeys() == nil && view.body.animationKeys() == nil)
            return
        }
        let stroke = try #require(view.outline.animation(forKey: "launch.strokeEnd") as? CABasicAnimation)
        #expect(stroke.fromValue as? Int == 0)
        #expect(stroke.duration == Motion.duration(.launch))
        let fill = try #require(view.body.animation(forKey: "launch.opacity") as? CABasicAnimation)
        #expect(fill.beginTime > 0, "the body fills in after the outline starts")
        #expect(fill.fillMode == .backwards)
    }

    @Test(arguments: [false, true])
    func bloomCondensesWithoutOvershoot(reduceMotion: Bool) throws {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = reduceMotion
        let view = make()
        view.reveal(.bloom)
        #expect(CATransform3DIsIdentity(view.mark.transform))
        #expect(view.mark.shadowOpacity == 0)
        if reduceMotion {
            #expect(view.mark.animationKeys() == ["launch.opacity"])
            return
        }
        let scale = try #require(view.mark.animation(forKey: "launch.transform") as? CABasicAnimation)
        let from = try #require(scale.fromValue as? CATransform3D)
        #expect(from.m11 > 1, "shrinks to size, never grows past it")
        #expect(Self.controlPoints(scale.timingFunction) == Self.controlPoints(Motion.fadeCurve))
        #expect(view.mark.animation(forKey: "launch.shadowOpacity") != nil)
    }

    @Test(arguments: [false, true])
    func entranceStaysUnderFourHundredMilliseconds(reduceMotion: Bool) {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = reduceMotion
        #expect(Motion.duration(.launch) < 0.4)
        #expect(Motion.duration(.launch) > 0)
    }

    @Test func traceDrawsTheOutlineAboveTheBody() {
        let view = make()
        #expect(view.outline.superlayer === view.mark, "not inside the body, whose opacity hides it while it draws")
        #expect(view.mark.sublayers?.last === view.outline)
    }

    private static func controlPoints(_ curve: CAMediaTimingFunction?) -> [Float] {
        guard let curve else { return [] }
        return [1, 2].flatMap { index -> [Float] in
            var point: [Float] = [0, 0]
            curve.getControlPoint(at: index, values: &point)
            return point
        }
    }

    @Test func concealFadesOut() {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = false
        let view = make()
        view.reveal(.bloom)
        view.conceal()
        #expect(!view.isRevealed)
        #expect(view.revealedStyle == nil)
    }
}
