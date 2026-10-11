import AppKit
@testable import CmuxNextDesign
import Testing

/// Hover feedback as Edge draws it (cx-f6i7): the fill eases in fast,
/// clears at once, a press shows at once and outlives the pointer leaving,
/// and Reduce Motion makes all of it instant. Checked on what the fill layer
/// would draw: its model color and whether a fade is running.
@MainActor
@Suite(.serialized)
struct ChromeHoverFadeTests {
    private func control() -> (ChromeHover, CALayer) {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 24))
        let hover = ChromeHover(view)
        return (hover, view.layer!.sublayers!.first!)
    }

    private func fade(_ layer: CALayer) -> CABasicAnimation? {
        layer.animation(forKey: "backgroundColor") as? CABasicAnimation
    }

    @Test func hoverEasesInAndClearsAtOnce() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (hover, fill) = control()
        hover.state.hovering = true
        #expect(fill.backgroundColor?.alpha ?? 0 > 0)
        #expect((fade(fill)?.duration ?? 0) > 0, "the highlight eases in")
        hover.state.hovering = false
        #expect(fill.backgroundColor?.alpha ?? 0 == 0)
        #expect(fade(fill) == nil, "a cleared highlight leaves no trail")
    }

    @Test func pressShowsAtOnceAndOutlivesTheExit() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (hover, fill) = control()
        hover.state.hovering = true
        hover.state.pressed = true
        #expect(fade(fill) == nil, "a press shows in the frame it lands")
        let pressed = fill.backgroundColor
        hover.state.hovering = false
        #expect(fill.backgroundColor == pressed, "leaving while pressed keeps the pressed fill")
        #expect(fade(fill) == nil)
    }

    @Test func reduceMotionMakesHoverInstant() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (hover, fill) = control()
        hover.state.hovering = true
        #expect(fill.backgroundColor?.alpha ?? 0 > 0)
        #expect(fade(fill) == nil)
    }

    @Test func paintedRowFillsFollowTheSameRule() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let layer = CALayer()
        ChromeHover.paint(layer, Palette.hoverFill, animated: true)
        #expect((fade(layer)?.duration ?? 0) > 0, "a sidebar row's highlight eases in")
        ChromeHover.paint(layer, nil, animated: true)
        #expect(fade(layer) == nil, "and clears at once")
    }
}
