import QuartzCore
import Testing
@testable import CmuxNextDesign

/// The indicator layer executes plans without leaking layers or animations.
@MainActor
struct StatusIndicatorLayerTests {
    func make() -> StatusIndicatorLayer {
        let indicator = StatusIndicatorLayer()
        indicator.colors = StatusIndicatorLayer.Colors(loading: CGColor(gray: 0.5, alpha: 1), attention: CGColor(gray: 0.6, alpha: 1),
                                                       danger: CGColor(gray: 0.3, alpha: 1), success: CGColor(gray: 0.7, alpha: 1))
        indicator.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        return indicator
    }

    @Test func idleHasNoSublayersAndIsHidden() {
        let indicator = make()
        indicator.apply(.hidden, config: StatusIndicatorConfig())
        #expect(indicator.liveSublayerCount == 0)
        #expect(indicator.layer.isHidden)
    }

    @Test func eachGlyphUsesTheFewestLayersAndIdleReleasesThem() {
        let indicator = make()
        let config = StatusIndicatorConfig()
        indicator.apply(StatusIndicatorPlan(glyph: .arc, animation: nil, tint: .loading), config: config)
        #expect(indicator.liveSublayerCount == 1)
        indicator.apply(StatusIndicatorPlan(glyph: .ring(progress: 0.3), animation: nil, tint: .loading), config: config)
        #expect(indicator.liveSublayerCount == 2)
        indicator.apply(StatusIndicatorPlan(glyph: .native, animation: nil, tint: .loading), config: config)
        #expect(indicator.liveSublayerCount == 1)
        indicator.apply(.hidden, config: config)
        #expect(indicator.liveSublayerCount == 0)
    }

    @Test func animationFollowsThePlanAndStopsWhenRemoved() {
        guard Motion.animatesLoops else { return }
        let indicator = make()
        let config = StatusIndicatorConfig()
        indicator.apply(.make(.busy, style: .arc, animates: true), config: config)
        #expect(indicator.runningAnimation == .spin)
        indicator.apply(.make(.busy, style: .native, animates: true), config: config)
        #expect(indicator.runningAnimation == .step)
        indicator.apply(.make(.busy, style: .dot, animates: true), config: config)
        #expect(indicator.runningAnimation == .pulse)
        indicator.apply(.make(.busy, style: .dot, animates: false), config: config)
        #expect(indicator.runningAnimation == nil)
        indicator.apply(.make(.busy(progress: 0.5), style: .arc, animates: true), config: config)
        #expect(indicator.runningAnimation == nil)
    }

    @Test func nativeStepsOncePerSpoke() throws {
        guard Motion.animatesLoops else { return }
        let step = try #require(Motion.stepAnimation(steps: 8) as? CAKeyframeAnimation)
        #expect(step.values?.count == 8)
        #expect(step.calculationMode == .discrete)
        #expect(Motion.stepAnimation(steps: 1) == nil)
    }

    @Test func configChangeRestartsTheAnimation() {
        guard Motion.animatesLoops else { return }
        let indicator = make()
        indicator.apply(.make(.busy, style: .dot, animates: true), config: StatusIndicatorConfig(pulseLow: 0.35))
        let before = indicator.layer.sublayers?.first?.animation(forKey: "pulse") as? CABasicAnimation
        indicator.apply(.make(.busy, style: .dot, animates: true), config: StatusIndicatorConfig(pulseLow: 0.1))
        let after = indicator.layer.sublayers?.first?.animation(forKey: "pulse") as? CABasicAnimation
        #expect((before?.toValue as? Float) == 0.35)
        #expect((after?.toValue as? Float) == 0.1)
    }

    @Test func explicitHostFlipUnflipsTheGlyphSpace() {
        let host = CALayer()
        host.isGeometryFlipped = true
        let indicator = make()
        host.addSublayer(indicator.layer)
        indicator.hostIsFlipped = true
        #expect(indicator.layer.isGeometryFlipped)
        indicator.hostIsFlipped = false
        #expect(!indicator.layer.isGeometryFlipped)
    }

    @Test func nativeSpokesComeFromAppKitAtFullResolution() throws {
        let image = try #require(NativeSpinnerImage.image(side: 12, scale: 2))
        #expect(image.width == 24)
        #expect(NativeSpinnerImage.image(side: 0, scale: 2) == nil)
    }
}
