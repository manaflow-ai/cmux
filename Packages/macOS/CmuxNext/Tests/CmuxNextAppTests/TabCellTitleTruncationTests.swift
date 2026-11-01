import Testing
import CmuxNextDesignTokens
@testable import CmuxNextTabs

@MainActor
struct TabCellTitleTruncationTests {
    @Test func tabChipTitlesTruncateInTheMiddle() {
        let cell = TabCell(item: TabItem(id: TabID("helper-1"), title: "Helper 1"))

        #expect(cell.titleLayer.truncation == .middle)
    }

    @Test func clippedTitleUsesVisibleWidthAtRestAndFullSpanForMarquee() {
        let geometry = TitleFadeGeometry(textWidth: 160, span: 120, visibleWidth: 72,
                                         leadingPadding: 8, trailingPadding: 0, fadeWidth: 12,
                                         restWidth: 72)

        #expect(geometry.layerWidth(marquee: false) == 72)
        #expect(geometry.layerWidth(marquee: true) == 160)
    }
}
