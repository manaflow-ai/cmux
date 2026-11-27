@testable import CmuxNextDesign
import Testing

/// POLISH rows are 26–28 pt. Compact is the shipped density, so its list rows sit in that range.
@Suite struct PolishDensityTests {
    @Test func compactPaletteRowsAreInThePolishRange() {
        #expect((26...28).contains(MetricTunables.paletteRowHeight.compact))
    }
}
