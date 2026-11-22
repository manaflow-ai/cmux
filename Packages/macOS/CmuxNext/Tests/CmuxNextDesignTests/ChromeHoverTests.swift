import AppKit
import QuartzCore
import Testing
@testable import CmuxNextDesign

/// The shared chrome hover: one tonal step per state from theme tokens
/// (pressed over selected over hovered), focus as an outline, and fills
/// that fade with `MotionFade.hover` or apply at once. Reduce Motion is
/// pinned both ways: CI runners have it on, the capture minis off.
@MainActor
@Suite(.serialized)
struct ChromeHoverTests {
    @Test func fillPrecedenceIsPressedThenSelectedThenHovered() {
        let rest = NSColor.red
        #expect(ChromeHover.fillColor(.init()) == nil)
        #expect(ChromeHover.fillColor(.init(), rest: rest) == rest)
        #expect(ChromeHover.fillColor(.init(hovering: true), rest: rest) == Palette.hoverFill)
        #expect(ChromeHover.fillColor(.init(hovering: true, selected: true)) == Palette.selectionFill)
        #expect(ChromeHover.fillColor(.init(hovering: true, pressed: true, selected: true)) == Palette.pressedFill)
        #expect(ChromeHover.fillColor(.init(focused: true)) == nil, "focus is an outline, never a fill")
    }

    @Test(arguments: [false, true])
    func animatedPaintFadesWithTheHoverToken(reduceMotion: Bool) throws {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = reduceMotion
        let layer = CALayer()
        ChromeHover.paint(layer, Palette.hoverFill, animated: true)
        #expect(layer.backgroundColor == Palette.hoverFill.cgColor)
        let duration = Motion.duration(.hover)
        if duration > 0 {
            let fade = try #require(layer.animation(forKey: "backgroundColor") as? CABasicAnimation)
            #expect(fade.duration == duration)
            #expect((fade.fromValue as! CGColor).alpha == 0, "fades in from the same color at alpha 0, not black")
        } else {
            #expect(layer.animation(forKey: "backgroundColor") == nil)
        }
        if reduceMotion { #expect(duration <= MotionFade.crossfade.baseDuration) }
    }

    @Test(arguments: [false, true])
    func instantPaintCancelsAFadeInFlight(reduceMotion: Bool) {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = reduceMotion
        let layer = CALayer()
        ChromeHover.paint(layer, Palette.hoverFill, animated: true)
        ChromeHover.paint(layer, Palette.pressedFill, animated: false)
        #expect(layer.backgroundColor == Palette.pressedFill.cgColor)
        #expect(layer.animation(forKey: "backgroundColor") == nil)
    }

    @Test func aFadedOutFillCountsAsClear() {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = false
        let layer = CALayer()
        ChromeHover.paint(layer, Palette.hoverFill, animated: false)
        ChromeHover.paint(layer, nil, animated: true)
        #expect(layer.backgroundColor?.alpha == 0)
        ChromeHover.paint(layer, nil, animated: false)
        #expect(layer.animation(forKey: "backgroundColor") != nil, "an unrelated repaint keeps the fade-out running")
        ChromeHover.paint(layer, Palette.hoverFill, animated: false)
        #expect(layer.backgroundColor == Palette.hoverFill.cgColor)
        #expect(layer.animation(forKey: "backgroundColor") == nil)
    }

    @Test func focusDrawsARingAndNoFill() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        let hover = ChromeHover(view, outset: NSSize(width: 2, height: 1))
        hover.layout()
        #expect(hover.fillFrame == NSRect(x: -2, y: -1, width: 44, height: 22), "the fill grows outward, nothing moves")
        hover.state.focused = true
        hover.refresh(animated: false)
        let fill = view.layer?.sublayers?.first
        #expect(fill?.borderWidth == Metrics.lineWidth(1.5))
        #expect((hover.shownFill?.alpha ?? 0) == 0)
        hover.state.focused = false
        hover.refresh(animated: false)
        #expect(fill?.borderWidth == 0)
    }
}
