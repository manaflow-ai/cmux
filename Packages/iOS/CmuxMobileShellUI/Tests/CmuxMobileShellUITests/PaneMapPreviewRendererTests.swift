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
}
