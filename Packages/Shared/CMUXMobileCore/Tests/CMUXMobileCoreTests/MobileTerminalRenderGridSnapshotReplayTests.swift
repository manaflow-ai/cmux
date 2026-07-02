import Foundation
import Testing
@testable import CMUXMobileCore

@Test func renderGridFullSnapshotDoesNotPresentBlankFrameBeforeContent() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 42,
        columns: 8,
        rows: 2,
        text: "visible\nrow",
        cursor: .init(row: 1, column: 3)
    )

    let presentedFrames = try ReplayPresentationProbe.presentedRows(
        from: frame.vtReplacementBytes(),
        rows: frame.rows,
        columns: frame.columns
    )

    #expect(presentedFrames.last?.contains { $0.contains("visible") } == true)
    #expect(
        !presentedFrames.contains(where: { frameRows in
            frameRows.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }),
        "full replay must not present the empty reset frame before synchronized snapshot content lands"
    )
}

private struct ReplayPresentationProbe {
    static func presentedRows(from data: Data, rows: Int, columns: Int) throws -> [[String]] {
        let text = try #require(String(data: data, encoding: .utf8))
        var probe = ReplayPresentationProbe(rows: rows, columns: columns)
        probe.consume(text)
        return probe.presentedFrames
    }

    private let rows: Int
    private let columns: Int
    private var cells: [[Character]]
    private var row = 0
    private var column = 0
    private var synchronized = false
    private(set) var presentedFrames: [[String]] = []

    private init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
        cells = Array(
            repeating: Array(repeating: Character(" "), count: columns),
            count: rows
        )
    }

    private mutating func consume(_ text: String) {
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "\u{1B}":
                index = consumeEscape(in: text, from: index)
            case "\u{0F}":
                index = text.index(after: index)
            case "\r":
                column = 0
                index = text.index(after: index)
            case "\n":
                row = min(row + 1, max(rows - 1, 0))
                index = text.index(after: index)
            default:
                if cells.indices.contains(row), cells[row].indices.contains(column) {
                    cells[row][column] = text[index]
                }
                column = min(column + 1, max(columns - 1, 0))
                index = text.index(after: index)
            }
        }
    }

    private mutating func consumeEscape(in text: String, from escapeIndex: String.Index) -> String.Index {
        var index = text.index(after: escapeIndex)
        guard index < text.endIndex else { return index }
        if text[index] == "c" {
            clearScreen()
            presentIfUnsynchronized()
            return text.index(after: index)
        }
        guard text[index] == "[" else {
            while index < text.endIndex, isESCIntermediateByte(text[index]) {
                index = text.index(after: index)
            }
            return index < text.endIndex ? text.index(after: index) : index
        }
        index = text.index(after: index)
        let parametersStart = index
        while index < text.endIndex, !isCSIFinalByte(text[index]) {
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return index }
        let parameters = String(text[parametersStart..<index])
        consumeCSI(parameters: parameters, final: text[index])
        return text.index(after: index)
    }

    private mutating func consumeCSI(parameters: String, final: Character) {
        switch final {
        case "h" where parameters == "?2026":
            synchronized = true
        case "l" where parameters == "?2026":
            synchronized = false
            recordFrame()
        case "H", "f":
            let values = csiIntegerParameters(parameters)
            row = min(max((values.first ?? 1) - 1, 0), max(rows - 1, 0))
            column = min(max((values.dropFirst().first ?? 1) - 1, 0), max(columns - 1, 0))
        case "G":
            column = min(max((csiIntegerParameters(parameters).first ?? 1) - 1, 0), max(columns - 1, 0))
        case "J":
            if parameters.contains("2") {
                clearScreen()
                presentIfUnsynchronized()
            }
        case "K":
            if parameters.contains("2"), cells.indices.contains(row) {
                cells[row] = Array(repeating: Character(" "), count: columns)
                presentIfUnsynchronized()
            }
        default:
            break
        }
    }

    private mutating func clearScreen() {
        cells = Array(
            repeating: Array(repeating: Character(" "), count: columns),
            count: rows
        )
        row = 0
        column = 0
    }

    private mutating func presentIfUnsynchronized() {
        if !synchronized {
            recordFrame()
        }
    }

    private mutating func recordFrame() {
        presentedFrames.append(cells.map { String($0) })
    }

    private func isCSIFinalByte(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            return false
        }
        return (0x40...0x7E).contains(scalar.value)
    }

    private func isESCIntermediateByte(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else {
            return false
        }
        return (0x20...0x2F).contains(scalar.value)
    }

    private func csiIntegerParameters(_ parameters: String) -> [Int] {
        parameters
            .split(separator: ";")
            .map { component in
                let digits = component.drop { !$0.isNumber }
                return Int(digits) ?? 1
            }
    }
}
