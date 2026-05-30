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
        "\u{1B}[1;1Halpha" +
        "\u{1B}[3;1H beta" +
        "\u{1B}[3;6H"
    )
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
