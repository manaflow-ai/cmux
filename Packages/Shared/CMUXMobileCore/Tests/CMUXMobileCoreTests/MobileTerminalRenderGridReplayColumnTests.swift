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

    let expectedCells: [(column: Int, character: Character)] = [
        (0, "A"),
        (1, "▶"),
        (3, "B"),
        (4, "界"),
        (6, "C"),
        (7, "🏁"),
        (9, "D"),
        (10, "e\u{301}"),
        (11, "Z"),
    ]
    for expected in expectedCells {
        #expect(cells[0][expected.column] == expected.character)
    }
}

private func replayedCells(
    from data: Data,
    rows: Int,
    columns: Int,
    widthOf: (Character) -> Int
) throws -> [[Character?]] {
    let text = try #require(String(data: data, encoding: .utf8))
    var cells = Array(
        repeating: Array<Character?>(repeating: nil, count: columns),
        count: rows
    )
    var row = 0
    var column = 0
    var index = text.startIndex
    while index < text.endIndex {
        if text[index] == "\u{1B}" {
            index = consumeEscape(
                in: text,
                from: index,
                row: &row,
                column: &column,
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
        row = max(0, (values.first ?? 1) - 1)
        column = max(0, (values.dropFirst().first ?? 1) - 1)
    case "G":
        column = max(0, (csiIntegerParameters(parameters).first ?? 1) - 1)
    case "K":
        if parameters == "2", cells.indices.contains(row) {
            cells[row] = Array<Character?>(repeating: nil, count: cells[row].count)
        }
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
