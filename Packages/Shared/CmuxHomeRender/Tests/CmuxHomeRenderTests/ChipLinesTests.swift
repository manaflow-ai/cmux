import CoreGraphics
import Testing
@testable import CmuxHomeRender

/// The first-run chips' line breaking (Chief's `ChiefFirstRunView`): one
/// centered row when they fit, else 2 + 1 with the third centered, and a
/// chip never narrower than its natural width while the pane can hold it.
@Suite struct ChipLinesTests {
    /// About the three starters' natural widths at 13 pt.
    static let widths: [CGFloat] = [205, 190, 210]
    static let gap: CGFloat = 8

    /// The chips' width in a pane: at most 680 pt, 16 pt in from each side.
    static func available(pane: CGFloat) -> CGFloat { max(0, min(680, pane - 32)) }

    @Test(arguments: [700.0, 900.0, 1200.0])
    func oneCenteredRowWhenTheyFit(pane: Double) {
        let available = Self.available(pane: CGFloat(pane))
        let lines = ChipLines(gap: Self.gap).layout(widths: Self.widths, available: available)
        #expect(lines.count == 1)
        let row = lines[0]
        #expect(row.map(\.index) == [0, 1, 2])
        #expect(row.map(\.width) == Self.widths)
        let total: CGFloat = 205 + 190 + 210 + 2 * Self.gap
        #expect(row[0].x == floor((available - total) / 2))
        #expect(row[1].x == row[0].x + 205 + Self.gap)
        #expect(row[2].x == row[1].x + 190 + Self.gap)
        #expect(row[2].x + 210 <= available)
    }

    @Test func wrapsTwoPlusOneWithTheThirdCentered() {
        let available = Self.available(pane: 500)
        let lines = ChipLines(gap: Self.gap).layout(widths: Self.widths, available: available)
        #expect(lines.map { $0.map(\.index) } == [[0, 1], [2]])
        let pair: CGFloat = 205 + Self.gap + 190
        #expect(lines[0][0].x == floor((available - pair) / 2))
        #expect(lines[1][0].x == floor((available - 210) / 2))
        // Nothing is cut while the pane can hold each chip.
        #expect(lines.flatMap { $0 }.map(\.width) == Self.widths)
    }

    @Test func oneChipPerLineWhenOnlyOneFits() {
        let lines = ChipLines(gap: Self.gap).layout(widths: Self.widths, available: 300)
        #expect(lines.map { $0.map(\.index) } == [[0], [1], [2]])
        #expect(lines[1][0].x == floor((300 - 190) / 2))
    }

    @Test func aChipWiderThanThePaneTakesTheFullWidth() {
        let lines = ChipLines(gap: Self.gap).layout(widths: [400, 100], available: 250)
        #expect(lines.count == 2)
        #expect(lines[0][0] == ChipLines.Placement(index: 0, x: 0, width: 250))
        #expect(lines[1][0].width == 100)
    }

    @Test func noChips() {
        #expect(ChipLines(gap: Self.gap).layout(widths: [], available: 600).isEmpty)
    }
}
