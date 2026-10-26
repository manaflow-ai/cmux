import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Lawrence 2026-10-20 (screen recording of Home's "Chief" pill popover: "animation needs to be
/// better"). At 120 fps the card appeared at full size in one frame and, on close, held for about
/// 75 ms and then vanished: the open and close faded the window's alpha, which the glass card
/// did not show, and grew it from 0.97 on a 0.135 s spring, too small and short to read as
/// coming out of the pill. Every native popup (`NativePopupHost`, `PopupFade`, the group
/// editors, the corner panels) shares `openPopup` / `closePopup`, so the fix is there: the
/// window stays opaque, and the card's own layer fades and grows from 0.95 about the pill on
/// the `popover` spring (~0.25 s); the close mirrors it, faster.
@MainActor @Suite(.serialized) struct PopupGrowMotionTests {
    private static let pivot = CGPoint(x: 150, y: 200)

    /// A borderless window on screen, at alpha 0 as a popup owner leaves it before an open.
    private static func popupWindow() throws -> (NSWindow, CALayer) {
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        content.wantsLayer = true
        let layer = try #require(content.layer)
        window.alphaValue = 0
        window.orderFrontRegardless()
        try #require(window.screen != nil)
        return (window, layer)
    }

    /// The popup adds its animations: a screen that is awake and speed not "off". Checks only the
    /// animations it queues, so a Mac mini whose display does not advance frames still runs it.
    static func queuesAnimations() async -> Bool {
        guard let screen = NSScreen.main else { return false }
        return Motion.speed != .off && !DisplaySleep.shared.isAsleep(screen)
    }

    /// The x scale a `sublayerTransform` value holds.
    private static func scale(_ value: Any?) -> CGFloat? {
        (value as? NSValue).map { $0.caTransform3DValue.m11 }
    }

    @Test(.enabled("needs a screen and animation speed on, or every popup snaps") { await Self.queuesAnimations() })
    func anOpenFadesAndGrowsTheCardOutOfItsControlWithTheWindowOpaque() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (window, layer) = try Self.popupWindow()
        defer { window.resetPopupScale(); window.orderOut(nil) }

        window.openPopup(pivot: Self.pivot)

        #expect(window.alphaValue == 1, "the window alpha fade does not show on the glass card")
        let fade = try #require(layer.animation(forKey: "opacity") as? CABasicAnimation, "the card does not fade in")
        #expect((fade.fromValue as? NSNumber)?.floatValue == 0)
        #expect(layer.opacity == 1)
        let grow = try #require(layer.animation(forKey: "sublayerTransform") as? CASpringAnimation, "the card does not grow")
        let from = try #require(Self.scale(grow.fromValue))
        #expect(abs(from - 0.95) < 0.001, "grows from \(from), too little to read as coming out of the control")
        // The pivot stays put: the card grows out of the control, not out of its own middle.
        let start = try #require(grow.fromValue as? NSValue).caTransform3DValue
        #expect(abs(start.m41 + Self.pivot.x * start.m11 - Self.pivot.x) < 0.01)
        #expect(abs(start.m42 + Self.pivot.y * start.m22 - Self.pivot.y) < 0.01)
        // Spring ~0.25 s: visibly a motion, never sluggish.
        let response = 2 * Double.pi / sqrt(grow.stiffness / grow.mass)
        #expect(abs(response - 0.25) < 0.02, "spring response \(response)")
        #expect(grow.damping / (2 * sqrt(grow.stiffness * grow.mass)) < 1, "no hint of spring")
    }

    @Test(.enabled("needs a screen and animation speed on, or every popup snaps") { await Self.queuesAnimations() })
    func aCloseMirrorsTheOpenFasterAndThenEnds() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (window, layer) = try Self.popupWindow()
        defer { window.orderOut(nil) }
        window.openPopup(pivot: Self.pivot)
        let openGrow = try #require(layer.animation(forKey: "sublayerTransform"))

        var ended = false
        window.closePopup(pivot: Self.pivot) { ended = true }

        #expect(window.alphaValue == 1, "the window alpha fade does not show on the glass card")
        let fade = try #require(layer.animation(forKey: "opacity"), "the card does not fade out")
        #expect(layer.opacity == 0)
        #expect(fade.duration > 0.1, "a close of \(fade.duration) s reads as a cut")
        #expect(fade.duration < openGrow.duration, "the close is not faster than the open")
        let shrink = try #require(layer.animation(forKey: "sublayerTransform"))
        let to = try #require(Self.scale((shrink as? CABasicAnimation)?.toValue))
        #expect(to < 1 && to > 0.95, "shrinks to \(to)")
        // The end needs frames on screen; a mini whose display does not advance skips this part.
        if await GUIAnimationTestSupport.animatesHere() {
            #expect(await GUIAnimationTestSupport.settle { ended }, "the close never ended")
        }
        window.resetPopupScale()
        #expect(layer.opacity == 1 && CATransform3DIsIdentity(layer.sublayerTransform))
    }

    @Test(.enabled("needs a screen and animation speed on, or every popup snaps") { await Self.queuesAnimations() })
    func underReduceMotionThePopupOnlyCrossfadesAtItsSize() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (window, layer) = try Self.popupWindow()
        defer { window.resetPopupScale(); window.orderOut(nil) }

        window.openPopup(pivot: Self.pivot)

        #expect(window.alphaValue == 1)
        #expect(layer.animation(forKey: "sublayerTransform") == nil, "Reduce Motion: no grow")
        #expect(CATransform3DIsIdentity(layer.sublayerTransform))
        let fade = layer.animation(forKey: "opacity")
        #expect((fade?.duration ?? 0) <= MotionFade.crossfade.baseDuration, "Reduce Motion: at most a short crossfade")
    }
}
