import CoreGraphics
import Testing
@testable import CmuxNextDesign

/// Small labeled surfaces (notes, toasts, count badges) take the theme's
/// item corner, never a capsule.
@MainActor
@Suite struct ChipCornerRadiusTests {
    @Test func aChipIsNeverACapsule() {
        for height: CGFloat in [14, 16, 20, 24, 28, 40] {
            let radius = Metrics.chipCornerRadius(height: height)
            #expect(radius > 0)
            #expect(radius <= Metrics.itemCornerRadius)
            #expect(radius <= height / 4)
        }
    }

    @Test func aTallChipTakesTheItemRadius() {
        #expect(Metrics.chipCornerRadius(height: 40) == Metrics.itemCornerRadius)
    }
}
