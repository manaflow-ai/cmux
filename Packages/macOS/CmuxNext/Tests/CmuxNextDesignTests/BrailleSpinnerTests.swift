import QuartzCore
import Testing
@testable import CmuxNextDesign

/// The braille status indicator style: terminal spinner frames as tinted
/// masks, stepped in the render server, still under Reduce Motion.
@MainActor
@Suite(.serialized)
struct BrailleSpinnerTests {
    func make() -> StatusIndicatorLayer {
        let indicator = StatusIndicatorLayer()
        indicator.colors = StatusIndicatorLayer.Colors(loading: CGColor(gray: 0.5, alpha: 1), attention: CGColor(gray: 0.6, alpha: 1),
                                                       danger: CGColor(gray: 0.3, alpha: 1), success: CGColor(gray: 0.7, alpha: 1))
        indicator.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        return indicator
    }

    @Test func framesAreTheTerminalSpinner() {
        #expect(String(BrailleSpinnerImage.frames) == "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    }

    /// One mask per frame at the backing pixel size, each a different
    /// glyph, in the terminal font or the monospaced fallback.
    @Test(arguments: [nil, "Menlo", "No Such Font"] as [String?])
    func everyFrameRendersADistinctMask(family: String?) {
        let images = BrailleSpinnerImage.images(side: 12, scale: 2, family: family)
        #expect(images.count == BrailleSpinnerImage.frames.count)
        #expect(images.allSatisfy { $0.width == 24 && $0.height == 24 })
        let inks = images.map(Self.ink)
        #expect(inks.allSatisfy { $0 > 0 })
        #expect(Set(images.map(Self.bytes)).count == images.count)
    }

    @Test func theLoadingTintColorsTheMask() throws {
        let indicator = make()
        indicator.apply(.make(.busy, style: .braille, animates: false), config: StatusIndicatorConfig())
        #expect(indicator.liveSublayerCount == 1)
        let braille = try #require(indicator.layer.sublayers?.first)
        #expect(braille.backgroundColor == CGColor(gray: 0.5, alpha: 1))
        #expect(braille.mask?.contents != nil)
        indicator.apply(.hidden, config: StatusIndicatorConfig())
        #expect(indicator.liveSublayerCount == 0)
    }

    /// Reduce Motion off: the frames step, discretely, once per spinner
    /// period. On: no animation, and the first frame stays.
    @Test(arguments: [false, true])
    func reduceMotionShowsAStillGlyph(reduceMotion: Bool) throws {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = reduceMotion
        let indicator = make()
        indicator.apply(.make(.busy, style: .braille, animates: Motion.animatesLoops), config: StatusIndicatorConfig())
        let mask = try #require(indicator.layer.sublayers?.first?.mask)
        let first = try #require(BrailleSpinnerImage.images(side: 12, scale: 2, family: nil).first)
        #expect(mask.contents.map { $0 as! CGImage } === first)
        if reduceMotion {
            #expect(indicator.runningAnimation == nil)
            #expect(Motion.framesAnimation([first, first]) == nil)
        } else {
            #expect(indicator.runningAnimation == .frames)
            let frames = try #require(mask.animation(forKey: "frames") as? CAKeyframeAnimation)
            #expect(frames.keyPath == "contents")
            #expect(frames.calculationMode == .discrete)
            #expect(frames.values?.count == BrailleSpinnerImage.frames.count)
            #expect(frames.duration == Motion.period(.spinner))
        }
    }

    @Test func switchingStylesReleasesTheBrailleLayer() {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = false
        let indicator = make()
        let config = StatusIndicatorConfig()
        indicator.apply(.make(.busy, style: .braille, animates: true), config: config)
        #expect(indicator.runningAnimation == .frames)
        indicator.apply(.make(.busy, style: .arc, animates: true), config: config)
        #expect(indicator.liveSublayerCount == 1)
        #expect(indicator.runningAnimation == .spin)
    }

    private static func bytes(_ image: CGImage) -> Data {
        image.dataProvider?.data.map { $0 as Data } ?? Data()
    }

    private static func ink(_ image: CGImage) -> Int {
        bytes(image).reduce(0) { $0 + Int($1) }
    }
}
