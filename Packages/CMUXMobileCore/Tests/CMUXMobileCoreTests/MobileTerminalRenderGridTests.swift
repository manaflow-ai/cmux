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
        "\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J" +
        "\u{1B}[1;1H\u{1B}[0malpha" +
        "\u{1B}[3;1H beta" +
        "\u{1B}[0m\u{1B}[?25h\u{1B}[3;6H"
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
        "\u{1B}[2;1H\u{1B}[2K" +
        "\u{1B}[3;1H\u{1B}[2K" +
        "\u{1B}[2;1H\u{1B}[0mchanged" +
        "\u{1B}[0m"
    )
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
