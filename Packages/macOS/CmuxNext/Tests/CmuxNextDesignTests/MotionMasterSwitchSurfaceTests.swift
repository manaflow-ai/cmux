import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Turning the master switch `ui.animations.enabled` off (or one category off) makes the real
/// animation entry points apply their change in one frame and add no Core Animation animation
/// (plans/cmux-next/motion-DESIGN.md). Every animation in the app goes through these gate
/// helpers (`scripts/cmux-next/check-motion.sh`), so a still gate is a still app.
@MainActor @Suite(.serialized) struct MotionMasterSwitchSurfaceTests {
    /// Runs `body` with the live switches set, then puts them back. Reduce Motion is pinned off so
    /// the host's accessibility setting cannot make a moving category look still.
    private func with(enabled: Bool, disabled: Set<MotionCategory> = [], _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let (oldEnabled, oldDisabled, oldSpeed) = (design.animationsEnabled, design.disabledAnimationCategories, design.animationSpeed)
        Motion.reduceMotionOverride = false
        design.animationSpeed = .fast
        design.animationsEnabled = enabled
        design.disabledAnimationCategories = disabled
        defer {
            design.animationsEnabled = oldEnabled
            design.disabledAnimationCategories = oldDisabled
            design.animationSpeed = oldSpeed
            Motion.reduceMotionOverride = nil
        }
        try body()
    }

    /// Whether every helper of `gate` applied at once and left no animation behind.
    private func gateIsStill(_ gate: MotionGate) -> Bool {
        let layer = CALayer()
        let fade = gate.set(layer, "opacity", to: Float(0), fade: .fadeIn, from: Float(1))
        let spring = gate.set(layer, "position", to: CGPoint(x: 40, y: 40), spring: .move, from: CGPoint.zero)
        let shrink = gate.set(layer, "transform.scale", to: 0.98, movementFade: .fadeOut, from: 1)
        gate.transaction(.fadeIn) { layer.backgroundColor = CGColor(gray: 1, alpha: 1) }
        gate.transaction(spring: .move) { layer.bounds = CGRect(x: 0, y: 0, width: 80, height: 20) }
        let view = NSView(frame: .zero)
        gate.animate(.move, in: view) { view.animator().frame = CGRect(x: 0, y: 0, width: 50, height: 50) }
        return fade == nil && spring == nil && shrink == nil
            && (layer.animationKeys() ?? []).isEmpty && layer.opacity == 0 && layer.position == CGPoint(x: 40, y: 40)
            && view.frame.width == 50 && gate.animation(.fadeIn) == nil
            && gate.spinAnimation() == nil && gate.stepAnimation(steps: 8) == nil && gate.pulseAnimation(low: 0.3) == nil
            && gate.flashAnimation() == nil && gate.passOverAnimation(.move) == nil
            && MotionMove.tween(.tabMove, in: gate) == nil && MotionMove.spring(.scroll, in: gate) == nil
            && gate.marqueeAnimation(keyPath: "transform.translation.x", travel: 300, sign: -1, now: 0) == nil
            && gate.duration(.fadeIn) == 0 && gate.duration(.move) == 0 && gate.period(.spinner) == nil
            && !gate.animatesMovement && !gate.animatesFades && !gate.animatesLoops
    }

    @Test func theMasterSwitchOffStillsEveryCategory() {
        with(enabled: false) {
            for category in MotionCategory.allCases {
                #expect(gateIsStill(Motion.gate(category)), "\(category) still animates with the master switch off")
            }
        }
    }

    @Test(arguments: MotionCategory.allCases)
    func oneCategoryOffStillsOnlyThatCategory(_ off: MotionCategory) {
        with(enabled: true, disabled: [off]) {
            #expect(gateIsStill(Motion.gate(off)), "\(off) still animates with its switch off")
            for other in MotionCategory.allCases where other != off {
                let gate = Motion.gate(other)
                #expect(gate.animatesMovement && gate.animatesFades && gate.animatesLoops, "\(other) stopped with only \(off) off")
                #expect(gate.set(CALayer(), "opacity", to: Float(0), fade: .fadeIn, from: Float(1)) != nil)
                #expect(gate.spinAnimation() != nil)
            }
        }
    }

    @Test func aPopupOpensAndClosesStillWithTheMasterSwitchOff() throws {
        try with(enabled: false) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            let content = try #require(window.contentView)
            content.wantsLayer = true
            let layer = try #require(content.layer)
            window.alphaValue = 0
            window.openPopup(pivot: CGPoint(x: 150, y: 200))
            #expect(window.alphaValue == 1, "the popup did not show at once")
            #expect(layer.animation(forKey: "sublayerTransform") == nil)
            var closed = false
            window.closePopup(pivot: CGPoint(x: 150, y: 200)) { closed = true }
            // A popup closes on its card layer and keeps the window opaque (Motion+Popup.swift); a
            // window with no screen to draw on, where nothing can animate, drops its alpha instead.
            if Motion.canAnimate(in: content) {
                #expect(window.alphaValue == 1)
                #expect(layer.opacity == 0, "the card did not hide at once")
                #expect(layer.animation(forKey: "opacity") == nil)
            } else {
                #expect(window.alphaValue == 0)
            }
            #expect(closed, "the close waited for an animation")
            #expect(layer.animation(forKey: "sublayerTransform") == nil)
            window.resetPopupScale()
        }
    }

    @Test func aClippedTitleRunsNoMarqueeWithItsCategoryOff() {
        func clippedLabel() -> MarqueeLabel {
            let label = MarqueeLabel(gate: Motion.sidebar, frame: CGRect(x: 0, y: 0, width: 40, height: 16))
            label.stringValue = String(repeating: "A long workspace title ", count: 8)
            label.layoutSubtreeIfNeeded()
            return label
        }
        with(enabled: true) {
            let label = clippedLabel()
            #expect(label.isTruncated, "the control title is not clipped, so this test proves nothing")
            #expect(label.startMarquee(), "a clipped title runs no marquee with every category on")
            label.stopMarquee()
        }
        with(enabled: true, disabled: [.sidebar]) {
            let label = clippedLabel()
            #expect(label.startMarquee() == false)
            #expect(!label.isMarqueeActive)
        }
    }
}
