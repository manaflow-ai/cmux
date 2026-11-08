import CmuxNextDesign
import CoreGraphics
import Testing

/// The concentric corner rule (Lawrence 2026-11-04: "inner radius is outer minus padding"):
/// pure math, fixed numbers.
@Suite struct ConcentricCornersTests {
    @Test(arguments: [(10.0, 2.0, 8.0), (14.0, 6.0, 8.0), (6.0, 2.0, 4.0), (4.0, 6.0, 0.0), (0.0, 2.0, 0.0), (8.0, 0.0, 8.0)])
    func theInnerRadiusIsTheOuterLessThePadding(outer: Double, padding: Double, inner: Double) {
        #expect(ConcentricCorners(outer: outer, padding: padding).inner == CGFloat(inner))
    }

    @Test func eachLevelInSubtractsThePaddingAgain() {
        let corners = ConcentricCorners(outer: 16, padding: 3)
        #expect((0...6).map { corners.radius(depth: $0) } == [16, 13, 10, 7, 4, 1, 0])
        #expect(corners.radius(depth: -1) == 19, "a ring outside the outer shape")
    }

    @Test func negativeInputsAreSquareAndNoGap() {
        let corners = ConcentricCorners(outer: -4, padding: -2)
        #expect(corners.outer == 0)
        #expect(corners.padding == 0)
    }

    @Test func aNestedShapeUsesItsOwnInset() {
        let corners = ConcentricCorners(outer: 10, padding: 2)
        #expect(corners.nested(in: 8, inset: 4) == 4, "a 16 pt close button in a 24 pt, 8 pt tab")
        #expect(corners.nested(in: 8, inset: 12) == 0)
        #expect(corners.nested(in: 8, inset: -6) == 14, "a rim 6 pt outside")
    }

    @Test func aRadiusNeverPassesHalfTheShorterSide() {
        let corners = ConcentricCorners(outer: 10, padding: 2)
        #expect(corners.radius(fitting: CGSize(width: 100, height: 24), radius: 20) == 12)
        #expect(corners.radius(fitting: CGSize(width: 6, height: 40), radius: 8) == 3)
        #expect(corners.radius(fitting: CGSize(width: 100, height: 100), radius: 8) == 8)
    }
}
