import Foundation
import Testing
@testable import CMUXMobileCore

@Test func renderGridFrameEncodesVisibleRowsAndCursor() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 42,
        columns: 8,
        rows: 4,
        text: "alpha   \n\n beta\n",
        cursor: .init(row: 2, column: 5)
    )

    #expect(frame.rowSpans == [
        .init(row: 0, column: 0, text: "alpha"),
        .init(row: 2, column: 0, text: " beta"),
    ])

    let decoded = try MobileTerminalRenderGridFrame.decodeJSONObject(frame.jsonObject())
    #expect(decoded == frame)
    #expect(String(data: frame.vtReplacementBytes(), encoding: .utf8) ==
        "\u{1B}c\u{1B}[0m\u{1B}[H\u{1B}[2J\u{1B}[3J" +
        "\u{1B}[1;1H\u{1B}[0malpha" +
        "\u{1B}[3;1H beta" +
        "\u{1B}[0m\u{1B}[2 q\u{1B}[?25h\u{1B}[3;6H"
    )
}

@Test func renderGridDeltaClearsOnlyChangedRows() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 43,
        columns: 8,
        rows: 4,
        text: "alpha\nchanged\n\nomega",
        full: false,
        changedRows: [1, 2]
    )

    #expect(frame.full == false)
    #expect(frame.clearedRows == [1, 2])
    #expect(frame.rowSpans == [
        .init(row: 1, column: 0, text: "changed"),
    ])
    #expect(String(data: frame.vtPatchBytes(), encoding: .utf8) ==
        "\u{1B}[0m\u{1B}[2;1H\u{1B}[2K" +
        "\u{1B}[0m\u{1B}[3;1H\u{1B}[2K" +
        "\u{1B}[2;1H\u{1B}[0mchanged" +
        "\u{1B}[0m"
    )
}

@Test func renderGridPatchPreservesRgbStylesAndCursorShape() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 45,
        columns: 8,
        rows: 4,
        cursor: .init(row: 1, column: 2, style: .bar, blinking: false),
        styles: [
            .init(id: 0, foreground: "#C0C0C0", background: "#101010"),
            .init(
                id: 1,
                foreground: "#FF0000",
                background: "#0000FF",
                bold: true,
                underline: true
            ),
        ],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 1, text: "red"),
        ]
    )

    let vt = try #require(String(data: frame.vtPatchBytes(), encoding: .utf8))
    #expect(vt.contains("\u{1B}[0;38;2;192;192;192;48;2;16;16;16m"))
    #expect(vt.contains("\u{1B}[0;1;4;38;2;255;0;0;48;2;0;0;255mred"))
    #expect(vt.contains("\u{1B}[6 q\u{1B}[?25h\u{1B}[2;3H"))
}

@Test func renderGridFilteredRowsKeepStyledSpans() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 46,
        columns: 8,
        rows: 4,
        styles: [
            .init(id: 0, foreground: "#FFFFFF", background: "#000000"),
            .init(id: 1, foreground: "#00FF00", background: "#000000"),
        ],
        rowSpans: [
            .init(row: 0, column: 0, text: "same"),
            .init(row: 1, column: 0, styleID: 1, text: "green"),
        ]
    )

    let delta = try frame.filteredRows([1], full: false)

    #expect(delta.full == false)
    #expect(delta.clearedRows == [1])
    #expect(delta.styles == frame.styles)
    #expect(delta.rowSpans == [.init(row: 1, column: 0, styleID: 1, text: "green")])
    #expect(try #require(String(data: delta.vtPatchBytes(), encoding: .utf8))
        .contains("\u{1B}[0;38;2;0;255;0;48;2;0;0;0mgreen"))
}

@Test func renderGridSpanCellWidthSupportsWideCells() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 47,
        columns: 2,
        rows: 1,
        rowSpans: [
            .init(row: 0, column: 0, text: "界", cellWidth: 2),
        ]
    )

    #expect(frame.plainRows() == ["界 "])
}

@Test func renderGridDecodesReplayFramesFromPreviousShape() throws {
    let object: [String: Any] = [
        "format": MobileTerminalRenderGridFrame.currentFormat,
        "surface_id": "terminal-a",
        "state_seq": NSNumber(value: 44),
        "columns": 8,
        "rows": 4,
        "styles": [["id": 0]],
        "row_spans": [
            ["row": 0, "column": 0, "style_id": 0, "text": "alpha"],
        ],
    ]

    let frame = try MobileTerminalRenderGridFrame.decodeJSONObject(object)

    #expect(frame.full)
    #expect(frame.clearedRows.isEmpty)
    #expect(frame.rowSpans == [.init(row: 0, column: 0, text: "alpha")])
}

@Test func renderGridRejectsInvalidSpanCoordinates() throws {
    #expect(throws: MobileTerminalRenderGridError.invalidColumn(9)) {
        _ = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-a",
            stateSeq: 1,
            columns: 8,
            rows: 4,
            rowSpans: [
                .init(row: 0, column: 9, text: "overflow"),
            ]
        )
    }
}
