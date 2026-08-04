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

    @Test func boundedPreviewUsesLatestScrollbackAndViewportRows() throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-preview",
            stateSeq: 1,
            columns: 4,
            rows: 3,
            rowSpans: [
                .init(row: 0, column: 0, text: "v0"),
                .init(row: 1, column: 0, text: "v1"),
                .init(row: 2, column: 0, text: "v2"),
            ],
            scrollbackRows: 4,
            scrollbackSpans: [
                .init(row: 0, column: 0, text: "s0"),
                .init(row: 1, column: 0, text: "s1"),
                .init(row: 2, column: 0, text: "s2"),
                .init(row: 3, column: 0, text: "s3"),
            ]
        )

        #expect(frame.paneMapPreview(maximumRows: 4).textRows == [
            "s3  ", "v0  ", "v1  ", "v2  ",
        ])
    }

    @Test func alternateScreenPreviewIgnoresPrimaryScrollback() throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-preview",
            stateSeq: 1,
            columns: 4,
            rows: 2,
            rowSpans: [
                .init(row: 0, column: 0, text: "a0"),
                .init(row: 1, column: 0, text: "a1"),
            ],
            activeScreen: .alternate,
            scrollbackRows: 2,
            scrollbackSpans: [
                .init(row: 0, column: 0, text: "s0"),
                .init(row: 1, column: 0, text: "s1"),
            ]
        )

        #expect(frame.paneMapPreview().textRows == ["a0  ", "a1  "])
    }

    @Test func previewKeepsRendererEffectiveBackground() throws {
        var effective = TerminalTheme.monokai
        effective.background = "#123456"

        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-preview",
            stateSeq: 1,
            columns: 2,
            rows: 1,
            rowSpans: [],
            terminalBackground: "#abcdef",
            terminalTheme: effective
        )

        #expect(frame.paneMapPreview().terminalTheme == effective)
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

    @Test func aggregateWidthDoesNotGuessBetweenAmbiguousGraphemes() {
        let partiallyExpanded = MobileTerminalRenderGridFrame.RowSpan(
            row: 0,
            column: 0,
            text: "¡¡",
            cellWidth: 3
        )
        let fullyExpanded = MobileTerminalRenderGridFrame.RowSpan(
            row: 0,
            column: 0,
            text: "¡¡",
            cellWidth: 4
        )

        #expect(partiallyExpanded.resolvedCharacterCellWidths == nil)
        #expect(fullyExpanded.resolvedCharacterCellWidths == [2, 2])
    }

    @Test func aggregateWidthDoesNotGuessWhichWideGraphemeContracted() {
        let partiallyContracted = MobileTerminalRenderGridFrame.RowSpan(
            row: 0,
            column: 0,
            text: "界界",
            cellWidth: 3
        )
        let fullyContracted = MobileTerminalRenderGridFrame.RowSpan(
            row: 0,
            column: 0,
            text: "界界",
            cellWidth: 2
        )

        #expect(partiallyContracted.resolvedCharacterCellWidths == nil)
        #expect(fullyContracted.resolvedCharacterCellWidths == [1, 1])
    }

    @Test func decReverseVideoResolvesFromFinalModeSetting() throws {
        let reenabled = try Self.frame(
            columns: 2,
            rowCount: 1,
            rowSpans: [.init(row: 0, column: 0, text: "ab")],
            modes: [
                .init(code: 5, on: true),
                .init(code: 5, on: false),
                .init(code: 5, on: true),
            ]
        ).paneMapPreview()

        let disabledLast = try Self.frame(
            columns: 2,
            rowCount: 1,
            rowSpans: [.init(row: 0, column: 0, text: "ab")],
            modes: [
                .init(code: 5, on: true),
                .init(code: 5, on: false),
            ]
        ).paneMapPreview()

        // Replay applies mode settings in order (last wins); the preview must
        // agree so a frame that re-disables reverse video does not render
        // permanently inverted. Legacy frames reverse the fallback theme.
        let fallback = TerminalTheme.monokai
        let reenabledTheme = reenabled.resolvedTerminalTheme(fallback: fallback)
        let disabledTheme = disabledLast.resolvedTerminalTheme(fallback: fallback)
        let base = fallback.validatedOrDefault()

        #expect(reenabledTheme.foreground == base.background)
        #expect(reenabledTheme.background == base.foreground)
        #expect(disabledTheme.foreground == base.foreground)
        #expect(disabledTheme.background == base.background)
    }

    private static func frame(
        columns: Int,
        rowCount: Int,
        rowSpans: [MobileTerminalRenderGridFrame.RowSpan],
        cursorRow: Int? = nil,
        modes: [MobileTerminalRenderGridFrame.ModeSetting] = []
    ) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-preview",
            stateSeq: 1,
            columns: columns,
            rows: rowCount,
            cursor: cursorRow.map {
                MobileTerminalRenderGridFrame.Cursor(row: $0, column: 0)
            },
            rowSpans: rowSpans,
            modes: modes
        )
    }
}
