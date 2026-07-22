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

    @Test func completePreviewKeepsShortTerminalContentAtTheTop() throws {
        let preview = try Self.frame(
            columns: 4,
            rowCount: 40,
            rowSpans: [
                .init(row: 0, column: 0, text: "top"),
                .init(row: 2, column: 0, text: "end"),
            ]
        ).paneMapPreview()

        #expect(preview.firstSourceRow == 0)
        #expect(preview.rows.count == 40)
        #expect(preview.textRows[0] == "top ")
        #expect(preview.textRows[2] == "end ")
        #expect(preview.textRows[39] == "    ")
    }

    @Test func completePreviewPreservesTUIStylesAndWideGlyphContinuations() throws {
        let styles: [MobileTerminalRenderGridFrame.Style] = [
            .default,
            .init(id: 1, foreground: "#00ff00", background: "#001100", bold: true),
            .init(id: 2, inverse: true),
        ]
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-preview",
            stateSeq: 1,
            columns: 6,
            rows: 2,
            styles: styles,
            rowSpans: [
                .init(row: 0, column: 0, styleID: 1, text: "界A", cellWidth: 3),
                .init(row: 1, column: 1, styleID: 2, text: "BOX"),
            ]
        )

        let preview = frame.paneMapPreview()

        #expect(preview.rows[0][0].text == "界")
        #expect(preview.rows[0][0].styleID == 1)
        #expect(preview.rows[0][0].columnSpan == 2)
        #expect(preview.rows[0][1].text.isEmpty)
        #expect(preview.rows[0][1].styleID == 1)
        #expect(preview.rows[0][1].columnSpan == 0)
        #expect(preview.rows[1][1].styleID == 2)
        #expect(preview.stylesByID[1]?.background == "#001100")
        #expect(preview.stylesByID[2]?.inverse == true)
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
