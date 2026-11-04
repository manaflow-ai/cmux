import CmuxNextDesign
import CmuxNextDesignTokens
import CoreGraphics
import Testing

/// The sidebar's densities are one design at four sizes: every size is Normal's at the density's scale.
@Suite struct SidebarDensityProportionTests {
    private func tokens(_ density: SidebarDensity) -> SidebarRowTokens {
        SidebarRowTokens(density: density, textSize: .small, base: .init(
            rowHeight: 24, space1: 2, space2: 4, space3: 6, space4: 8, cornerRadius: 6, body: 12, caption: 10.5,
            listRowHeight: 28, rowTitle: 13, rowDetail: 12))
    }

    @Test func eachDensityDrawsItsSizes() {
        let sizes = SidebarDensity.allCases.map { density in
            let t = tokens(density)
            return [t.rowHeight, t.titleSize, t.captionSize, t.horizontalInset]
        }
        #expect(sizes == [
            [22, 10.5, 9.5, 6],
            [25, 11.5, 11, 7],
            [28, 13, 12, 8],
            [31, 14.5, 13, 9],
            [28, 13, 12, 8],
        ])
    }

    @Test func normalIsTheCodexSidebarExactly() {
        let normal = tokens(.normal)
        #expect(normal.card.paddingY == 4)
        #expect(normal.card.gap == 2)
        #expect(normal.card.buttonRadius == 6)
    }

    /// Rounding aside, no size drifts from its density's scale: row, text and inset move together.
    @Test func everySizeStaysWithinRoundingOfTheScale() {
        let normal = tokens(.normal)
        for density in SidebarDensity.allCases {
            let t = tokens(density)
            #expect(abs(t.rowHeight - normal.rowHeight * t.scale) <= 0.5)
            #expect(abs(t.horizontalInset - normal.horizontalInset * t.scale) <= 0.5)
            #expect(abs(t.titleSize - normal.titleSize * t.scale) <= 0.25)
            #expect(abs(t.captionSize - normal.captionSize * t.scale) <= 0.25)
        }
    }

    /// At an Interface Size the base sizes are off the grid: Normal must not round them.
    @Test func normalKeepsAScaledBaseExactly() {
        let scaled = SidebarRowTokens(density: .normal, textSize: .small, base: .init(
            rowHeight: 28.8, space1: 2.4, space2: 4.8, space3: 7.2, space4: 9.6, cornerRadius: 7.2, body: 14.4, caption: 12.6,
            listRowHeight: 33.6, rowTitle: 15.6, rowDetail: 14.4))
        #expect(scaled.rowHeight == 33.6)
        #expect(scaled.horizontalInset == 9.6)
        #expect(scaled.titleSize == 15.6)
        #expect(scaled.captionSize == 14.4)
    }

    @Test func customSizesStillWin() {
        let custom = SidebarRowTokens(density: .ultraCompact, textSize: .small, base: .init(
            rowHeight: 24, space1: 2, space2: 4, space3: 6, space4: 8, cornerRadius: 6, body: 12, caption: 10.5,
            listRowHeight: 28, rowTitle: 13, rowDetail: 12, customRowHeight: 40, customRowPadding: 12, customTitle: 16))
        #expect(custom.rowHeight == 40)
        #expect(custom.horizontalInset == 12)
        #expect(custom.titleSize == 16)
    }
}
