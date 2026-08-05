import CoreGraphics
import Testing
@testable import CmuxPanes

@Suite("Pane share ratios")
struct PaneShareRatioTests {
    @Test(arguments: [1, 2, 3, 4, 5, 6])
    func focusedPartsAgainstOneSiblingPartProduceExpectedShare(focusedParts: Int) throws {
        let ratio = try #require(PaneShareRatio(focusedParts: focusedParts, siblingParts: 1))

        #expect(ratio.share == CGFloat(focusedParts) / CGFloat(focusedParts + 1))
    }

    @Test(arguments: [
        (0, 1),
        (1, 0),
        (-1, 1),
        (1, -1),
    ])
    func nonPositivePartsAreRejected(parts: (focused: Int, sibling: Int)) {
        #expect(PaneShareRatio(
            focusedParts: parts.focused,
            siblingParts: parts.sibling
        ) == nil)
    }

    @Test func shareCalculationDoesNotOverflowLargePartCounts() throws {
        let ratio = try #require(PaneShareRatio(
            focusedParts: Int.max,
            siblingParts: Int.max
        ))

        #expect(ratio.share == 0.5)
    }
}
