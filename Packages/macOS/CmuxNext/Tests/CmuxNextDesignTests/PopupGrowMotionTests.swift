import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Lawrence 2026-10-20 (screen recording of Home's "Chief" pill popover: "animation needs to be
/// better"). At 120 fps the card appeared at full size in one frame and, on close, held for about
/// 75 ms and then vanished: the open and close faded the window's alpha, which the glass card
/// did not show, and grew it from 0.97 on a 0.135 s spring, too small and short to read as
/// coming out of the pill. Shared popup owners keep their grow/fade entrance by default; menu
/// hosts opt out explicitly with `entrance: false`, and every close fades and shrinks faster.
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

    /// The x scale a `sublayerTransform` value holds.
    private static func scale(_ value: Any?) -> CGFloat? {
        (value as? NSValue).map { $0.caTransform3DValue.m11 }
    }

    @Test(.enabled("needs an awake display that can advance animations") { await GUIAnimationTestSupport.animatesHere() })
    func anOpenWithoutExplicitEntranceUsesTheSharedEntrance() throws {
        let design = DesignSettings.shared
        let oldSettings = (design.animationsEnabled, design.disabledAnimationCategories, design.animationSpeed)
        design.animationsEnabled = true
        design.disabledAnimationCategories.remove(.overlays)
        design.animationSpeed = .fast
        defer {
            design.animationsEnabled = oldSettings.0
            design.disabledAnimationCategories = oldSettings.1
            design.animationSpeed = oldSettings.2
        }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (window, layer) = try Self.popupWindow()
        defer { window.resetPopupScale(); window.orderOut(nil) }

        window.openPopup(pivot: Self.pivot)

        #expect(window.alphaValue == 1)
        #expect(layer.animation(forKey: "opacity") != nil, "the shared popup entrance fades in")
        #expect(layer.animation(forKey: "sublayerTransform") != nil, "the shared popup entrance grows in")
    }

    @Test(.enabled("needs an awake display that can advance animations") { await GUIAnimationTestSupport.animatesHere() })
    func anOpenWithEntranceFalseShowsTheCardAtOnce() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (window, layer) = try Self.popupWindow()
        defer { window.resetPopupScale(); window.orderOut(nil) }

        window.openPopup(pivot: Self.pivot, entrance: false)

        #expect(window.alphaValue == 1)
        #expect(layer.animation(forKey: "opacity") == nil, "the menu fades in")
        #expect(layer.animation(forKey: "sublayerTransform") == nil, "the menu grows in")
        #expect(layer.opacity == 1)
        #expect(CATransform3DIsIdentity(layer.sublayerTransform))
    }

    @Test(.enabled("needs an awake display that can advance animations") { await GUIAnimationTestSupport.animatesHere() })
    func aCloseMirrorsTheOpenFasterAndThenEnds() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let (window, layer) = try Self.popupWindow()
        defer { window.orderOut(nil) }
        window.openPopup(pivot: Self.pivot, entrance: true)
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

    @Test(.enabled("needs an awake display that can advance animations") { await GUIAnimationTestSupport.animatesHere() })
    func underReduceMotionThePopupOnlyCrossfadesAtItsSize() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (window, layer) = try Self.popupWindow()
        defer { window.resetPopupScale(); window.orderOut(nil) }

        window.openPopup(pivot: Self.pivot, entrance: true)

        #expect(window.alphaValue == 1)
        #expect(layer.animation(forKey: "sublayerTransform") == nil, "Reduce Motion: no grow")
        #expect(CATransform3DIsIdentity(layer.sublayerTransform))
        let fade = layer.animation(forKey: "opacity")
        #expect((fade?.duration ?? 0) <= MotionFade.crossfade.baseDuration, "Reduce Motion: at most a short crossfade")
    }
}
