import AppKit
import Testing
@testable import CmuxNextDesign

/// HoverReveal (R83, R97, R100, R120): views that fade in, in place, while
/// the pointer is over their region, while a hold is active, or while one of
/// them has keyboard focus. One instance per region and per view.
@MainActor @Suite(.serialized) struct HoverRevealTests {
    final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// Animations off, so alpha changes apply at once.
    private func withInstantMotion(_ body: () throws -> Void) rethrows {
        let saved = DesignSettings.shared.animationSpeed
        defer { DesignSettings.shared.animationSpeed = saved }
        DesignSettings.shared.animationSpeed = .off
        try body()
    }

    private func makeRegion() -> (NSView, NSView) {
        let region = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        let button = FocusableView(frame: NSRect(x: 200, y: 8, width: 24, height: 24))
        region.addSubview(button)
        return (region, button)
    }

    @Test func revealFollowsThePointerHoldsFocusAndTheSetting() {
        var state = HoverRevealState()
        #expect(!state.isRevealed)
        state.pointerInside = true
        #expect(state.isRevealed)
        state.pointerInside = false
        state.holds = 1
        #expect(state.isRevealed)
        state.holds = 0
        state.focusInside = true
        #expect(state.isRevealed)
        state.focusInside = false
        state.isEnabled = false
        #expect(state.isRevealed, "disabled means always shown")
    }

    @Test func addedViewsFadeInPlace() throws {
        try withInstantMotion {
            let (region, button) = makeRegion()
            let frame = button.frame
            let reveal = HoverReveal(region: region)
            #expect(reveal.add(button))
            #expect(button.alphaValue == 0)
            reveal.setPointerInside(true)
            #expect(reveal.isRevealed)
            #expect(button.alphaValue == 1)
            #expect(button.frame == frame)
            reveal.setPointerInside(false)
            #expect(button.alphaValue == 0)
            #expect(button.frame == frame)
            #expect(!button.isHidden, "a hidden view stays in place and in the accessibility tree")
        }
    }

    @Test func disabledKeepsTheViewsShown() {
        withInstantMotion {
            let (region, button) = makeRegion()
            let reveal = HoverReveal(region: region)
            reveal.add(button)
            reveal.isEnabled = false
            #expect(button.alphaValue == 1)
            reveal.setPointerInside(false)
            #expect(button.alphaValue == 1)
        }
    }

    @Test func aHoldKeepsTheRevealUntilReleased() {
        withInstantMotion {
            let (region, button) = makeRegion()
            let reveal = HoverReveal(region: region)
            reveal.add(button)
            reveal.setPointerInside(true)
            let hold = reveal.hold()
            reveal.setPointerInside(false)
            #expect(button.alphaValue == 1)
            hold.release()
            #expect(button.alphaValue == 0)
            hold.release()
            #expect(reveal.state.holds == 0, "a second release is a no-op")
        }
    }

    /// Keyboard focus on a hidden view reveals its region (a focus hold).
    @Test func keyboardFocusRevealsTheRegion() throws {
        try withInstantMotion {
            let (region, button) = makeRegion()
            let window = NSWindow(contentRect: region.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = region
            let reveal = HoverReveal(region: region)
            reveal.add(button)
            #expect(button.alphaValue == 0)
            #expect(window.makeFirstResponder(button))
            #expect(reveal.isRevealed)
            #expect(button.alphaValue == 1)
            #expect(window.makeFirstResponder(nil))
            #expect(!reveal.isRevealed)
            window.contentView = nil
        }
    }

    /// Leaving the window (closing it) resets the reveal and every hold.
    @Test func leavingTheWindowResetsTheReveal() {
        withInstantMotion {
            let (region, button) = makeRegion()
            let host = NSView(frame: region.frame)
            let window = NSWindow(contentRect: region.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.addSubview(region)
            let reveal = HoverReveal(region: region)
            reveal.add(button)
            reveal.setPointerInside(true)
            _ = reveal.hold()
            #expect(reveal.isRevealed)
            region.removeFromSuperview()
            #expect(!reveal.isRevealed)
            #expect(reveal.state.holds == 0)
            #expect(button.alphaValue == 0)
            window.contentView = nil
        }
    }

    /// One instance per view and per region: a second claim is refused.
    @Test func aViewBelongsToOneRevealOnly() {
        HoverReveal.assertsOnConflict = false
        defer { HoverReveal.assertsOnConflict = true }
        let (region, button) = makeRegion()
        let first = HoverReveal(region: region)
        #expect(first.add(button))
        let other = HoverReveal(region: NSView())
        #expect(!other.add(button))
        #expect(HoverReveal.owner(of: button) === first)
        #expect(HoverReveal.owner(ofRegion: region) === first)
        first.remove(button)
        #expect(HoverReveal.owner(of: button) == nil)
        #expect(other.add(button))
    }
}
