import CMUXMobileCore
import Testing
@testable import CmuxMobileShellUI

@Suite struct PaneMapPreviewRendererTests {
    @Test func emptyGridProducesSpaceCanvas() {
        let rows = PaneMapPreviewRenderer.rows(
            columns: 4,
            rowCount: 2,
            rowSpans: []
        )

        #expect(rows == ["    ", "    "])
    }

    @Test func laterOverlappingSpanWinsInSourceOrder() {
        let rows = PaneMapPreviewRenderer.rows(
            columns: 4,
            rowCount: 1,
            rowSpans: [
                .init(row: 0, column: 0, text: "abcd"),
                .init(row: 0, column: 1, text: "XY"),
            ]
        )

        #expect(rows == ["aXYd"])
    }

    @Test func wideGlyphKeepsFollowingSpansInProducerColumns() {
        let rows = PaneMapPreviewRenderer.rows(
            columns: 6,
            rowCount: 1,
            rowSpans: [
                .init(row: 0, column: 0, text: "界A", cellWidth: 3),
                .init(row: 0, column: 4, text: "Z"),
            ]
        )

        #expect(rows == ["界A Z "])
    }

    @Test func laterSpanClearsWideGlyphWhoseContinuationItOverlaps() {
        let rows = PaneMapPreviewRenderer.rows(
            columns: 4,
            rowCount: 1,
            rowSpans: [
                .init(row: 0, column: 0, text: "界A", cellWidth: 3),
                .init(row: 0, column: 1, text: "XY"),
            ]
        )

        #expect(rows == [" XY "])
    }

    @Test func textIsTruncatedAtFinalGridColumn() {
        let rows = PaneMapPreviewRenderer.rows(
            columns: 4,
            rowCount: 1,
            rowSpans: [
                .init(row: 0, column: 2, text: "WXYZ"),
            ]
        )

        #expect(rows == ["  WX"])
    }

    @Test func windowFollowsTopAnchoredContentOnTallGrid() {
        // A cleared tall grid (like a phone-attached surface right after
        // `clear`) keeps content at the top; the window must include it
        // instead of showing the grid's blank bottom rows.
        let rows = PaneMapPreviewRenderer.rows(
            columns: 3,
            rowCount: 40,
            rowSpans: [
                .init(row: 0, column: 0, text: "top"),
                .init(row: 2, column: 0, text: "cat"),
            ],
            cursorRow: 3
        )

        #expect(rows.count == 20)
        #expect(rows[0] == "top")
        #expect(rows[2] == "cat")
    }

    @Test func windowStaysBottomAnchoredWhenContentFillsTail() {
        let rows = PaneMapPreviewRenderer.rows(
            columns: 3,
            rowCount: 40,
            rowSpans: [
                .init(row: 39, column: 0, text: "end"),
            ]
        )

        #expect(rows.count == 20)
        #expect(rows.last == "end")
    }
}
