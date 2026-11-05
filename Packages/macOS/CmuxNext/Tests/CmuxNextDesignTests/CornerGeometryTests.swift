import CoreGraphics
@testable import CmuxNextDesign
import QuartzCore
import Testing

/// The corner geometry variants (`chrome.cornerGeometry`, Leo 2026-11-05: "you can't mix straight
/// with curved"): one radius scale on design/grid.md's steps, concentric at every level, and a
/// default that changes nothing.
@MainActor @Suite struct CornerGeometryTests {
    /// Every radius a variant draws is a grid.md step (4, 6, 8, 12, 16), and each level is the
    /// one outside it less the one gap.
    @Test func theScaleIsOnTheGridAndConcentric() {
        let scale = CornerGeometry.Scale()
        let steps: Set<CGFloat> = [4, 6, 8, 12, 16]
        for radius in [scale.window, scale.card, scale.tab, scale.fill] { #expect(steps.contains(radius)) }
        #expect(scale.card == scale.window - scale.gap)
        #expect(scale.tab == scale.card - scale.gap)
        #expect(scale.fill == scale.tab - scale.gap)
    }

    /// Off is the default: no variant radius, no frame, four rounded tab corners.
    @Test func offChangesNothing() {
        #expect(CornerGeometry.tunable.defaultValue == .off)
        #expect(CornerGeometry.off.tabRadius == nil)
        #expect(CornerGeometry.off.cardRadius == nil)
        #expect(CornerGeometry.off.frameGap == nil)
        #expect(CornerGeometry.off.frameShade(isDark: true) == nil)
        #expect(CornerGeometry.off.tabRoundedCorners.contains([.layerMinXMinYCorner, .layerMaxXMaxYCorner]))
    }

    /// Square-leading rounds only the trailing corners; square tabs have no radius; the frame
    /// variants draw the card and its gap.
    @Test func eachVariantDrawsItsShape() {
        let leading = CornerGeometry.tabsSquareLeading.tabRoundedCorners
        #expect(!leading.contains(.layerMinXMinYCorner) && !leading.contains(.layerMinXMaxYCorner))
        #expect(leading.contains(.layerMaxXMinYCorner) && leading.contains(.layerMaxXMaxYCorner))
        #expect(CornerGeometry.tabsSquare.tabRadius == 0)
        #expect(!CornerGeometry.tabsSquare.drawsFrame && !CornerGeometry.tabsSquareLeading.drawsFrame)
        for frame in [CornerGeometry.framedCard, .matchedSidebar] {
            #expect(frame.drawsFrame)
            #expect(frame.cardRadius == Metrics.scale(12))
            #expect(frame.frameGap == Metrics.scale(4))
        }
    }

    /// The drawn pill (a drag snapshot) is square where the layer's corner mask is square.
    @Test func thePillPathIsSquareOnTheLeadingSideOnly() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 28)
        let path = CornerGeometry.pillPath(rect, radius: 8, rounded: CornerGeometry.tabsSquareLeading.tabRoundedCorners)
        #expect(path.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(path.contains(CGPoint(x: 0.5, y: 27.5)))
        #expect(!path.contains(CGPoint(x: 99.5, y: 0.5)))
        #expect(!path.contains(CGPoint(x: 99.5, y: 27.5)))
        let round = CornerGeometry.pillPath(rect, radius: 8, rounded: CornerGeometry.off.tabRoundedCorners)
        #expect(!round.contains(CGPoint(x: 0.5, y: 0.5)))
    }
}
