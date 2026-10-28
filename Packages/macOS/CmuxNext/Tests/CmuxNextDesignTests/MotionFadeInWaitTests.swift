import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// `MotionGate.fadeIn(_:layers:in:waitingUpTo:ended:)`, the split's new pane fade
/// (plans/cmux-next/motion-first-principles.md): only opacity animates, on the layers (Core Animation, no main-thread
/// step), the model opacity stays at rest, the content's first frame starts the fade, and with the gate still nothing
/// animates at all.
@MainActor @Suite(.serialized) struct MotionFadeInWaitTests {
    /// Runs `body` with the live switches set, then puts them back (Reduce Motion pinned off).
    private func with(enabled: Bool = true, disabled: Set<MotionCategory> = [], _ body: () throws -> Void) rethrows {
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

    /// A layer-backed view out of any window (`canAnimate` lets it animate) and a second layer (the pane's chrome).
    private func pane() -> (view: NSView, chrome: CALayer) {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.wantsLayer = true
        return (view, CALayer())
    }

    private func keyPaths(_ layer: CALayer) -> [String] {
        (layer.animationKeys() ?? []).compactMap { (layer.animation(forKey: $0) as? CAPropertyAnimation)?.keyPath }
    }

    @Test func theWaitHoldsOnlyOpacityAndKeepsTheModelAtRest() throws {
        try with {
            let (view, chrome) = pane()
            let layer = try #require(view.layer)
            let wait = Motion.panes.fadeIn(.fadeIn, layers: [layer, chrome], in: view, waitingUpTo: MotionScale.quick)
            #expect(wait != nil)
            for target in [layer, chrome] {
                #expect(keyPaths(target) == ["opacity"], "animates \(keyPaths(target))")
                #expect(target.opacity == 1, "the model opacity left its rest")
                let hold = try #require(target.animation(forKey: FadeInWait.holdKey) as? CAKeyframeAnimation)
                #expect(hold.isAdditive)
                #expect(hold.values?.first as? NSNumber == NSNumber(value: Float(-1)), "the hold does not start invisible")
                #expect(abs(hold.duration - (MotionScale.quick + Motion.panes.duration(.fadeIn))) < 1e-9)
            }
        }
    }

    @Test func theContentsFirstFrameStartsTheFadeFromZero() throws {
        try with {
            let (view, chrome) = pane()
            let layer = try #require(view.layer)
            let wait = try #require(Motion.panes.fadeIn(.fadeIn, layers: [layer, chrome], in: view, waitingUpTo: 1))
            wait.contentDrawn()
            #expect(wait.isSettled)
            for target in [layer, chrome] {
                #expect(target.animation(forKey: FadeInWait.holdKey) == nil, "the hold still holds")
                #expect(keyPaths(target) == ["opacity"], "animates \(keyPaths(target))")
                let fade = try #require((target.animationKeys() ?? []).compactMap { target.animation(forKey: $0) as? CABasicAnimation }.first)
                #expect(fade.isAdditive)
                #expect(fade.fromValue as? NSNumber == NSNumber(value: Float(-1)))
                #expect(abs(fade.duration - Motion.panes.duration(.fadeIn)) < 1e-9)
                #expect(target.opacity == 1)
            }
            // A second report changes nothing.
            wait.contentDrawn()
            #expect(keyPaths(layer) == ["opacity"])
        }
    }

    @Test func cancelShowsTheLayersAtRest() throws {
        try with {
            let (view, chrome) = pane()
            let layer = try #require(view.layer)
            let wait = try #require(Motion.panes.fadeIn(.fadeIn, layers: [layer, chrome], in: view, waitingUpTo: 1))
            wait.cancel()
            #expect((layer.animationKeys() ?? []).isEmpty && (chrome.animationKeys() ?? []).isEmpty)
            #expect(layer.opacity == 1 && chrome.opacity == 1)
        }
    }

    /// Content that drew already (its first-frame report comes in the call) is not held or faded, and its frame wait
    /// stops; content still waiting is held and its later report starts the fade (review of abf9c90495d: a handoff's
    /// docked chat faded again from 0).
    @Test func contentThatDrewAlreadyIsNotHeld() throws {
        try with {
            let (view, _) = pane()
            let layer = try #require(view.layer)
            var stopped = 0
            let none = Motion.panes.fadeIn(.fadeIn, layers: [layer], in: view, waitingUpTo: 1, whenDrawn: { drawn in
                drawn()
                return { stopped += 1 }
            })
            #expect(none == nil)
            #expect((layer.animationKeys() ?? []).isEmpty, "content that drew is held: \(layer.animationKeys() ?? [])")
            #expect(stopped == 1, "the frame wait did not stop")

            var report: (@MainActor () -> Void)?
            let wait = try #require(Motion.panes.fadeIn(.fadeIn, layers: [layer], in: view, waitingUpTo: 1, whenDrawn: { drawn in
                report = drawn
                return { stopped += 1 }
            }))
            #expect(layer.animation(forKey: FadeInWait.holdKey) != nil, "content still waiting is not held")
            report?()
            #expect(wait.isSettled && layer.animation(forKey: FadeInWait.holdKey) == nil, "the report did not start the fade")
            wait.cancel()
            #expect(stopped == 2, "cancel did not stop the frame wait")
        }
    }

    /// No animation at all: the master switch off, the panes category off, or speed off. The pane shows in this frame.
    @Test func aStillGateFadesNothing() throws {
        let cases: [(Bool, Set<MotionCategory>)] = [(false, []), (true, [.panes])]
        for (enabled, disabled) in cases {
            try with(enabled: enabled, disabled: disabled) {
                let (view, chrome) = pane()
                let layer = try #require(view.layer)
                #expect(Motion.panes.fadeIn(.fadeIn, layers: [layer, chrome], in: view, waitingUpTo: 1) == nil)
                #expect((layer.animationKeys() ?? []).isEmpty && (chrome.animationKeys() ?? []).isEmpty)
                #expect(layer.opacity == 1)
            }
        }
        let design = DesignSettings.shared, oldSpeed = design.animationSpeed
        design.animationSpeed = .off
        defer { design.animationSpeed = oldSpeed }
        let (view, _) = pane()
        let layer = try #require(view.layer)
        #expect(Motion.panes.fadeIn(.fadeIn, layers: [layer], in: view, waitingUpTo: 1) == nil)
    }
}
