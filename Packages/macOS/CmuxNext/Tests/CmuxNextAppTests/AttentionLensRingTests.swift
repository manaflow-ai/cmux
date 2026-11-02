import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// The attention ring is a glass lens by default (Leo, 2026-11-02: "I want more fisheye!"): a band
/// the lens bends inward, a caustic line and a specular rim, over a translucent stroke. Reduce
/// Transparency draws the flat, opaque stroke it had before.
@MainActor @Suite(.serialized) struct AttentionLensRingTests {
    static func overlay() -> PaneOverlayView {
        let view = PaneOverlayView()
        view.setFrameSize(NSSize(width: 400, height: 300))
        return view
    }

    static func show(_ view: PaneOverlayView) {
        view.update(showsRing: false, dim: 0, focusRing: FocusRingSettings(), border: PaneOverlayView.Border(shows: false),
                    attention: AttentionMark(generation: 1), attentionSettings: AttentionSettings(), animated: false)
    }

    static func alpha(_ color: CGColor?) -> CGFloat { color?.alpha ?? 0 }

    @Test func theDefaultRingIsAFisheyeLens() {
        #expect(AttentionLensLook.tunable.defaultValue == .fisheye)
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let view = Self.overlay()
        Self.show(view)
        #expect(view.attentionLens.look == .fisheye)
        #expect(view.attentionLens.showsBand, "the lens bends no light into the pane")
        #expect(view.attentionLens.bandDepth == AttentionLensLook.fisheye.depth)
        #expect(view.attentionLens.showsCaustic, "the lens focuses no caustic")
        #expect(view.attentionLens.showsSpecular, "the rim catches no light")
        #expect(!view.attentionLens.showsChromaticFringe, "the fisheye splits its caustic like the prism")
        #expect(Self.alpha(view.attentionLayer.borderColor) < 1, "the glass stroke is still solid")
        // The ring keeps its glow and the theme accent's hue.
        #expect(view.attentionGlowColor == Palette.accentFill.cgColor)
    }

    @Test func reduceTransparencyDrawsTheSolidRing() {
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = nil }
        let view = Self.overlay()
        Self.show(view)
        #expect(view.attentionLens.look == .solid)
        #expect(!view.attentionLens.showsBand)
        #expect(!view.attentionLens.showsCaustic)
        #expect(!view.attentionLens.showsSpecular)
        #expect(Self.alpha(view.attentionLayer.borderColor) == 1, "Reduce Transparency left the stroke see-through")
    }

    @Test func turningReduceTransparencyOffBringsTheLensBack() {
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = nil }
        let view = Self.overlay()
        Self.show(view)
        ReduceTransparency.shared.override = false
        Self.show(view)
        #expect(view.attentionLens.look == .fisheye)
        #expect(view.attentionLens.showsBand)
    }

    @Test(arguments: AttentionLensLook.allCases)
    func everyLookKeepsItsShape(_ look: AttentionLensLook) {
        #expect(look.isGlass == (look != .solid))
        #expect(look.effective(reduceTransparency: true) == .solid)
        #expect(look.effective(reduceTransparency: false) == look)
        #expect(look.splitsCaustic ? look.drawsCaustic : true, "a split caustic with no caustic")
        #expect((look.strokeAlpha < 1) == look.isGlass)
    }
}
