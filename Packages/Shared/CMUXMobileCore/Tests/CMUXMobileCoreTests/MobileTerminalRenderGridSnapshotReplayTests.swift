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

@Test func renderGridFullSnapshotEndsActiveHyperlinkBeforePaintingContent() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a",
        stateSeq: 43,
        columns: 8,
        rows: 1,
        text: "safe",
        cursor: .init(row: 0, column: 4)
    )

    let linkedText = try ReplayHyperlinkProbe.hyperlinkedTextPainted(from: frame.vtReplacementBytes())

    #expect(
        linkedText.isEmpty,
        "full replay must terminate any previously active OSC 8 hyperlink before painting snapshot cells"
    )
}

@Test func renderGridFullSnapshotClearsWithFrameDefaultBackground() throws {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: "terminal-a",
        stateSeq: 44,
        columns: 8,
        rows: 2,
        cursor: .init(row: 0, column: 1),
        styles: [
            .init(id: 0, background: "#112233"),
        ],
        rowSpans: [
            .init(row: 0, column: 0, styleID: 0, text: "x"),
        ]
    )

    let clearBackgrounds = try ReplayClearStyleProbe.clearBackgrounds(from: frame.vtReplacementBytes())

    #expect(!clearBackgrounds.isEmpty)
    #expect(
        clearBackgrounds.allSatisfy { $0 == "#112233" },
        "full replay clears must use the frame default background, not stale cursor style"
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
        if text[index] == "]" {
            return consumeOSC(in: text, from: text.index(after: index))
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

    private mutating func consumeOSC(in text: String, from oscIndex: String.Index) -> String.Index {
        var index = oscIndex
        while index < text.endIndex {
            if text[index] == "\u{07}" {
                return text.index(after: index)
            }
            if text[index] == "\u{1B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\\" {
                    return text.index(after: next)
                }
            }
            index = text.index(after: index)
        }
        return index
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

private struct ReplayClearStyleProbe {
    static func clearBackgrounds(from data: Data) throws -> [String] {
        let text = try #require(String(data: data, encoding: .utf8))
        var probe = ReplayClearStyleProbe()
        probe.consume(text)
        return probe.clearBackgrounds
    }

    private var activeBackground = "stale"
    private var clearBackgrounds: [String] = []

    private mutating func consume(_ text: String) {
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "\u{1B}" else {
                index = text.index(after: index)
                continue
            }
            index = consumeEscape(in: text, from: index)
        }
    }

    private mutating func consumeEscape(in text: String, from escapeIndex: String.Index) -> String.Index {
        var index = text.index(after: escapeIndex)
        guard index < text.endIndex else { return index }
        if text[index] == "]" {
            return consumeOSC(in: text, from: text.index(after: index))
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
        consumeCSI(parameters: String(text[parametersStart..<index]), final: text[index])
        return text.index(after: index)
    }

    private mutating func consumeOSC(in text: String, from oscIndex: String.Index) -> String.Index {
        var index = oscIndex
        while index < text.endIndex {
            if text[index] == "\u{07}" {
                return text.index(after: index)
            }
            if text[index] == "\u{1B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\\" {
                    return text.index(after: next)
                }
            }
            index = text.index(after: index)
        }
        return index
    }

    private mutating func consumeCSI(parameters: String, final: Character) {
        switch final {
        case "J" where parameters.contains("2"):
            clearBackgrounds.append(activeBackground)
        case "m":
            applySGR(parameters)
        default:
            break
        }
    }

    private mutating func applySGR(_ parameters: String) {
        let values = parameters
            .split(separator: ";")
            .map { Int($0) ?? 0 }
        if values.isEmpty {
            activeBackground = "default"
            return
        }
        var index = 0
        while index < values.count {
            switch values[index] {
            case 0:
                activeBackground = "default"
                index += 1
            case 48 where index + 4 < values.count && values[index + 1] == 2:
                activeBackground = String(
                    format: "#%02x%02x%02x",
                    values[index + 2],
                    values[index + 3],
                    values[index + 4]
                )
                index += 5
            default:
                index += 1
            }
        }
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
}

private struct ReplayHyperlinkProbe {
    static func hyperlinkedTextPainted(from data: Data) throws -> String {
        let text = try #require(String(data: data, encoding: .utf8))
        var probe = ReplayHyperlinkProbe()
        probe.consume(text)
        return probe.hyperlinkedText
    }

    private var hyperlinkActive = true
    private var hyperlinkedText = ""

    private mutating func consume(_ text: String) {
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "\u{1B}":
                index = consumeEscape(in: text, from: index)
            case "\u{0F}", "\r", "\n":
                index = text.index(after: index)
            default:
                if hyperlinkActive {
                    hyperlinkedText.append(text[index])
                }
                index = text.index(after: index)
            }
        }
    }

    private mutating func consumeEscape(in text: String, from escapeIndex: String.Index) -> String.Index {
        var index = text.index(after: escapeIndex)
        guard index < text.endIndex else { return index }
        if text[index] == "]" {
            return consumeOSC(in: text, from: text.index(after: index))
        }
        if text[index] == "[" {
            index = text.index(after: index)
            while index < text.endIndex, !isCSIFinalByte(text[index]) {
                index = text.index(after: index)
            }
            return index < text.endIndex ? text.index(after: index) : index
        }
        while index < text.endIndex, isESCIntermediateByte(text[index]) {
            index = text.index(after: index)
        }
        return index < text.endIndex ? text.index(after: index) : index
    }

    private mutating func consumeOSC(in text: String, from oscIndex: String.Index) -> String.Index {
        var index = oscIndex
        var payload = ""
        while index < text.endIndex {
            if text[index] == "\u{07}" {
                applyOSCPayload(payload)
                return text.index(after: index)
            }
            if text[index] == "\u{1B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "\\" {
                    applyOSCPayload(payload)
                    return text.index(after: next)
                }
            }
            payload.append(text[index])
            index = text.index(after: index)
        }
        return index
    }

    private mutating func applyOSCPayload(_ payload: String) {
        guard payload.hasPrefix("8;") else { return }
        hyperlinkActive = payload != "8;;"
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
}
