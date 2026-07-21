import Testing
@testable import CMUXMobileCore

@Suite struct MobileTerminalRenderGridPaneMapPreviewTests {
    @Test func emptyGridProducesSpaceCanvas() throws {
        let rows = try Self.frame(
            columns: 4,
            rowCount: 2,
            rowSpans: []
        ).paneMapPreviewRows()

        #expect(rows == ["    ", "    "])
    }

    @Test func laterOverlappingSpanWinsInSourceOrder() throws {
        let rows = try Self.frame(
            columns: 4,
            rowCount: 1,
            rowSpans: [
                .init(row: 0, column: 0, text: "abcd"),
                .init(row: 0, column: 1, text: "XY"),
            ]
        ).paneMapPreviewRows()

        #expect(rows == ["aXYd"])
    }

    @Test func wideGlyphKeepsFollowingSpansInProducerColumns() throws {
        let rows = try Self.frame(
            columns: 6,
            rowCount: 1,
            rowSpans: [
                .init(row: 0, column: 0, text: "界A", cellWidth: 3),
                .init(row: 0, column: 4, text: "Z"),
            ]
        ).paneMapPreviewRows()

        #expect(rows == ["界A Z "])
    }

    @Test func laterSpanClearsWideGlyphWhoseContinuationItOverlaps() throws {
        let rows = try Self.frame(
            columns: 4,
            rowCount: 1,
            rowSpans: [
                .init(row: 0, column: 0, text: "界A", cellWidth: 3),
                .init(row: 0, column: 1, text: "XY"),
            ]
        ).paneMapPreviewRows()

        #expect(rows == [" XY "])
    }

    @Test func spanAtFinalGridColumnFitsCanvas() throws {
        let rows = try Self.frame(
            columns: 4,
            rowCount: 1,
            rowSpans: [
                .init(row: 0, column: 2, text: "WX"),
            ]
        ).paneMapPreviewRows()

        #expect(rows == ["  WX"])
    }

    @Test func windowFollowsTopAnchoredContentOnTallGrid() throws {
        let rows = try Self.frame(
            columns: 3,
            rowCount: 40,
            rowSpans: [
                .init(row: 0, column: 0, text: "top"),
                .init(row: 2, column: 0, text: "cat"),
            ],
            cursorRow: 3
        ).paneMapPreviewRows()

        #expect(rows.count == 20)
        #expect(rows[0] == "top")
        #expect(rows[2] == "cat")
    }

    @Test func windowStaysBottomAnchoredWhenContentFillsTail() throws {
        let rows = try Self.frame(
            columns: 3,
            rowCount: 40,
            rowSpans: [
                .init(row: 39, column: 0, text: "end"),
            ]
        ).paneMapPreviewRows()

        #expect(rows.count == 20)
        #expect(rows.last == "end")
    }

    private static func frame(
        columns: Int,
        rowCount: Int,
        rowSpans: [MobileTerminalRenderGridFrame.RowSpan],
        cursorRow: Int? = nil
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-preview",
            stateSeq: 1,
            columns: columns,
            rows: rowCount,
            cursor: cursorRow.map {
                MobileTerminalRenderGridFrame.Cursor(row: $0, column: 0)
            },
            rowSpans: rowSpans
        )
    }
}
