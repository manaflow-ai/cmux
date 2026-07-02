import Foundation
import Testing
@testable import CMUXMobileCore

@Test func renderGridReplayPinsGlyphsToProducerColumnsWhenConsumerWidthDiffers() throws {
    let text = "A▶B界C🏁De\u{301}Z"
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 48,
        columns: 16,
        rows: 1,
        full: false,
        clearedRows: [0],
        rowSpans: [
            .init(row: 0, column: 0, text: text, cellWidth: 12),
        ]
    )

    let cells = try replayedCells(
        from: frame.vtPatchBytes(),
        rows: frame.rows,
        columns: frame.columns
    ) { character in
        switch character {
        case "界", "🏁":
            return 2
        default:
            return 1
        }
    }

    let expectedRow: [Character?] = [
        "A", "▶", nil, "B", "界", nil, "C", "🏁",
        nil, "D", "e\u{301}", "Z", nil, nil, nil, nil,
    ]
    #expect(cells[0] == expectedRow)
}

@Test func renderGridReplayDoesNotInferColumnsFromAmbiguousAggregateWidth() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 49,
        columns: 4,
        rows: 1,
        full: false,
        clearedRows: [0],
        rowSpans: [
            .init(row: 0, column: 0, text: "α🇰🇷B", cellWidth: 4),
        ]
    )

    #expect(String(data: frame.vtPatchBytes(), encoding: .utf8) ==
        "\u{1B}[0m\u{1B}[1;1H\u{1B}[2K" +
        "\u{1B}[1;1H\u{1B}[0mα🇰🇷B" +
        "\u{1B}[0m"
    )
}

@Test func renderGridReplaySanitizesC1ControlScalars() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 50,
        columns: 3,
        rows: 1,
        full: false,
        clearedRows: [0],
        rowSpans: [
            .init(row: 0, column: 0, text: "A\u{9B}B", cellWidth: 3),
        ]
    )

    #expect(String(data: frame.vtPatchBytes(), encoding: .utf8) ==
        "\u{1B}[0m\u{1B}[1;1H\u{1B}[2K" +
        "\u{1B}[1;1H\u{1B}[0mA B" +
        "\u{1B}[0m"
    )
}

@Test func renderGridDeltaReplaysAbsoluteRowsWhenOriginModeIsActive() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 51,
        columns: 8,
        rows: 4,
        full: false,
        clearedRows: [0],
        rowSpans: [
            .init(row: 0, column: 0, text: "alpha"),
        ],
        modes: [
            .init(code: 6, ansi: false, on: true),
            .init(code: 7, ansi: false, on: true),
        ]
    )

    var bytes = Data("\u{1B}[2;4r\u{1B}[?6h".utf8)
    bytes.append(frame.vtPatchBytes())
    let rows = renderedRows(try replayedCells(
        from: bytes,
        rows: frame.rows,
        columns: frame.columns,
        initialRows: [
            "────────",
            "row-one!",
            "row-two!",
            "row-tre!",
        ]
    ))

    #expect(rows[0] == "alpha   ")
    #expect(rows[1] == "row-one!")
    #expect(!rows[0].contains("─"))
}

private func replayedCells(
    from data: Data,
    rows: Int,
    columns: Int,
    initialRows: [String] = [],
    widthOf: (Character) -> Int = { _ in 1 }
) throws -> [[Character?]] {
    let text = try #require(String(data: data, encoding: .utf8))
    var cells = initialRows.isEmpty
        ? Array(repeating: Array<Character?>(repeating: nil, count: columns), count: rows)
        : cellRows(from: initialRows, rows: rows, columns: columns)
    var row = 0
    var column = 0
    var originMode = false
    var scrollRegionTop = 0
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "\u{1B}" {
            index = consumeEscape(
                in: text,
                from: index,
                row: &row,
                column: &column,
                originMode: &originMode,
                scrollRegionTop: &scrollRegionTop,
                cells: &cells
            )
            continue
        }
        if text[index] == "\r" {
            column = 0
            index = text.index(after: index)
            continue
        }
        if text[index] == "\n" {
            row += 1
            index = text.index(after: index)
            continue
        }

        let next = text.index(after: index)
        let character = Character(String(text[index..<next]))
        if cells.indices.contains(row), cells[row].indices.contains(column) {
            cells[row][column] = character
        }
        column += max(1, widthOf(character))
        index = next
    }
    return cells
}

private func consumeEscape(
    in text: String,
    from escapeIndex: String.Index,
    row: inout Int,
    column: inout Int,
    originMode: inout Bool,
    scrollRegionTop: inout Int,
    cells: inout [[Character?]]
) -> String.Index {
    var index = text.index(after: escapeIndex)
    guard index < text.endIndex else { return index }
    guard text[index] == "[" else {
        return text.index(after: index)
    }
    index = text.index(after: index)
    let parametersStart = index
    while index < text.endIndex, !isCSIFinalByte(text[index]) {
        index = text.index(after: index)
    }
    guard index < text.endIndex else { return index }
    let parameters = String(text[parametersStart..<index])
    switch text[index] {
    case "H", "f":
        let values = csiIntegerParameters(parameters)
        let rowBase = originMode ? scrollRegionTop : 0
        row = rowBase + max(0, (values.first ?? 1) - 1)
        column = max(0, (values.dropFirst().first ?? 1) - 1)
    case "G":
        column = max(0, (csiIntegerParameters(parameters).first ?? 1) - 1)
    case "K":
        if parameters == "2", cells.indices.contains(row) {
            cells[row] = Array<Character?>(repeating: nil, count: cells[row].count)
        }
    case "h", "l":
        let values = csiIntegerParameters(parameters)
        if parameters.hasPrefix("?"), values.contains(6) {
            originMode = text[index] == "h"
            row = originMode ? scrollRegionTop : 0
            column = 0
        }
    case "r":
        let values = csiIntegerParameters(parameters)
        scrollRegionTop = max(0, (values.first ?? 1) - 1)
        row = 0
        column = 0
    default:
        break
    }
    return text.index(after: index)
}

private func isCSIFinalByte(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first,
          character.unicodeScalars.count == 1 else {
        return false
    }
    return (0x40...0x7E).contains(scalar.value)
}

private func csiIntegerParameters(_ parameters: String) -> [Int] {
    parameters
        .split(separator: ";")
        .map { component in
            let digits = component.drop { !$0.isNumber }
            return Int(digits) ?? 1
        }
}

private func cellRows(from rows: [String], rows rowCount: Int, columns: Int) -> [[Character?]] {
    var cells = Array(
        repeating: Array<Character?>(repeating: nil, count: columns),
        count: rowCount
    )
    for (row, text) in rows.prefix(rowCount).enumerated() {
        for (column, character) in text.prefix(columns).enumerated() {
            cells[row][column] = character
        }
    }
    return cells
}

private func renderedRows(_ cells: [[Character?]]) -> [String] {
    cells.map { row in
        String(row.map { $0 ?? " " })
    }
}
