import Foundation

enum MobileTerminalGhosttyVTParser {
    static func row(from line: String, columns: Int) -> MobileTerminalGhosttyRow {
        var cells: [MobileTerminalGhosttyCell] = []
        for character in line {
            let width = terminalDisplayWidth(of: character)
            switch width {
            case 0:
                guard let targetIndex = cells.lastIndex(where: { !$0.isSpacer }) else { continue }
                cells[targetIndex].text.append(character)
            case 2:
                guard cells.count + 2 <= columns else { break }
                cells.append(MobileTerminalGhosttyCell(text: String(character), width: .wide))
                cells.append(MobileTerminalGhosttyCell(width: .spacerTail))
            default:
                guard cells.count < columns else { break }
                cells.append(MobileTerminalGhosttyCell(text: String(character)))
            }
        }
        while cells.count < columns {
            cells.append(.blank)
        }
        return MobileTerminalGhosttyRow(cells: cells)
    }
    
    private static func terminalLines(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
    
    struct StyledTerminalGrid {
        var rows: [MobileTerminalGhosttyRow]
        var cursorColumn: Int
        var cursorRow: Int
        var usesAbsoluteCursorAddressing: Bool
    }
    
    static func styledRows(from text: String, columns: Int) -> [MobileTerminalGhosttyRow] {
        styledGrid(from: text, columns: columns).rows
    }
    
    static func styledGrid(from text: String, columns: Int) -> StyledTerminalGrid {
        let resolvedColumns = max(1, columns)
        let text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.isEmpty else {
            return StyledTerminalGrid(rows: [], cursorColumn: 0, cursorRow: 0, usesAbsoluteCursorAddressing: false)
        }
        let wrapsOverflow = text.contains("\u{001B}")
    
        var rows: [[MobileTerminalGhosttyCell]] = [[]]
        var wrappedRowIndices = Set<Int>()
        var row = 0
        var column = 0
        var wrapPending = false
        var usesAbsoluteCursorAddressing = false
        var style = MobileTerminalGhosttyCellStyle()
        var index = text.startIndex
    
        func ensureRow(_ rowIndex: Int) {
            guard rowIndex >= 0 else { return }
            while rows.count <= rowIndex {
                rows.append([])
            }
        }
    
        func ensureCellStorage(row rowIndex: Int, through columnIndex: Int) {
            ensureRow(rowIndex)
            guard columnIndex >= 0 else { return }
            while rows[rowIndex].count <= columnIndex {
                rows[rowIndex].append(.blank)
            }
        }
    
        func setCell(_ cell: MobileTerminalGhosttyCell, atRow rowIndex: Int, column columnIndex: Int) {
            guard columnIndex >= 0, columnIndex < resolvedColumns else { return }
            ensureCellStorage(row: rowIndex, through: columnIndex)
            rows[rowIndex][columnIndex] = cell
        }
    
        func eraseLine(mode: Int) {
            ensureRow(row)
            switch mode {
            case 1:
                guard column >= 0 else { return }
                ensureCellStorage(row: row, through: min(column, max(columns - 1, 0)))
                let end = min(column, rows[row].count - 1)
                guard end >= 0 else { return }
                for index in 0...end {
                    rows[row][index] = .blank
                }
            case 2:
                rows[row].removeAll(keepingCapacity: true)
            default:
                guard column < resolvedColumns else { return }
                ensureCellStorage(row: row, through: max(column, 0))
                let start = max(column, 0)
                guard start < rows[row].count else { return }
                for index in start..<rows[row].count {
                    rows[row][index] = .blank
                }
            }
            if rows[row].isEmpty {
                wrappedRowIndices.remove(row)
            }
            wrapPending = false
        }
    
        func eraseDisplay(mode: Int) {
            switch mode {
            case 1:
                guard row >= 0 else { return }
                ensureRow(row)
                if row > 0 {
                    for rowIndex in 0..<row {
                        rows[rowIndex].removeAll(keepingCapacity: true)
                    }
                }
                let savedColumn = column
                eraseLine(mode: 1)
                column = savedColumn
            case 2, 3:
                rows = [[]]
                wrappedRowIndices.removeAll(keepingCapacity: true)
                row = 0
                column = 0
                wrapPending = false
            default:
                guard row >= 0 else { return }
                ensureRow(row)
                eraseLine(mode: 0)
                if row + 1 < rows.count {
                    rows.removeSubrange((row + 1)..<rows.count)
                    wrappedRowIndices = Set(wrappedRowIndices.filter { $0 <= row })
                }
            }
        }
    
        func moveCursor(row newRow: Int, column newColumn: Int) {
            row = max(0, newRow)
            column = max(0, newColumn)
            wrapPending = false
            ensureRow(row)
        }
    
        func applyEscapeAction(_ action: TerminalEscapeAction) {
            switch action {
            case .none:
                return
            case let .cursorPosition(newRow, newColumn):
                usesAbsoluteCursorAddressing = true
                moveCursor(row: newRow, column: newColumn)
            case let .cursorMove(rowDelta, columnDelta):
                moveCursor(row: row + rowDelta, column: column + columnDelta)
            case let .cursorColumn(newColumn):
                moveCursor(row: row, column: newColumn)
            case let .cursorRow(newRow):
                usesAbsoluteCursorAddressing = true
                moveCursor(row: newRow, column: column)
            case let .eraseDisplay(mode):
                eraseDisplay(mode: mode)
            case let .eraseLine(mode):
                eraseLine(mode: mode)
            }
        }
    
        func normalizedRows() -> [MobileTerminalGhosttyRow] {
            rows.enumerated().map { rowIndex, rowCells in
                var cells = Array(rowCells.prefix(resolvedColumns))
                while cells.count < resolvedColumns {
                    cells.append(.blank)
                }
                return MobileTerminalGhosttyRow(
                    cells: cells,
                    isWrapped: wrappedRowIndices.contains(rowIndex)
                )
            }
        }
    
        func appendLine() {
            row += 1
            column = 0
            wrapPending = false
            ensureRow(row)
        }
    
        func writeCell(_ cell: MobileTerminalGhosttyCell) {
            if wrapsOverflow, wrapPending {
                wrappedRowIndices.insert(row)
                row += 1
                column = 0
                wrapPending = false
                ensureRow(row)
            }
            guard column < resolvedColumns else { return }
            setCell(cell, atRow: row, column: column)
            if wrapsOverflow, column >= resolvedColumns - 1 {
                wrapPending = true
            } else {
                column += 1
            }
        }
    
        func writeCharacter(_ character: Character) {
            let width = terminalDisplayWidth(of: character)
            switch width {
            case 0:
                guard column > 0 else { return }
                ensureCellStorage(row: row, through: column - 1)
                for targetColumn in stride(from: column - 1, through: 0, by: -1) {
                    guard !rows[row][targetColumn].isSpacer else { continue }
                    rows[row][targetColumn].text.append(character)
                    return
                }
            case 2:
                if column >= resolvedColumns - 1 {
                    guard wrapsOverflow else { return }
                    wrappedRowIndices.insert(row)
                    row += 1
                    column = 0
                    wrapPending = false
                    ensureRow(row)
                }
                writeCell(MobileTerminalGhosttyCell(text: String(character), width: .wide, style: style))
                writeCell(MobileTerminalGhosttyCell(width: .spacerTail, style: style))
            default:
                writeCell(MobileTerminalGhosttyCell(text: String(character), style: style))
            }
        }
    
        while index < text.endIndex {
            if text[index] == "\u{001B}",
               let action = consumeEscapeSequence(in: text, index: &index, style: &style) {
                applyEscapeAction(action)
                continue
            }
    
            let character = text[index]
            index = text.index(after: index)
    
            switch character {
            case "\n":
                appendLine()
            case "\r":
                column = 0
                wrapPending = false
            case "\t":
                let nextTabStop = min(resolvedColumns, ((column / 8) + 1) * 8)
                while column < nextTabStop {
                    let previousRow = row
                    let previousColumn = column
                    writeCell(MobileTerminalGhosttyCell(text: " ", style: style))
                    if wrapPending, row == previousRow, column == previousColumn {
                        break
                    }
                }
            default:
                writeCharacter(character)
            }
        }
    
        if text.hasSuffix("\n"), rows.last?.isEmpty == true {
            rows.removeLast()
            row = max(row, 0)
            column = 0
        }
    
        return StyledTerminalGrid(
            rows: normalizedRows(),
            cursorColumn: min(max(column, 0), resolvedColumns - 1),
            cursorRow: max(row, 0),
            usesAbsoluteCursorAddressing: usesAbsoluteCursorAddressing
        )
    }
    
    private enum TerminalEscapeAction {
        case none
        case cursorPosition(row: Int, column: Int)
        case cursorMove(rowDelta: Int, columnDelta: Int)
        case cursorColumn(Int)
        case cursorRow(Int)
        case eraseDisplay(Int)
        case eraseLine(Int)
    }
    
    private static func consumeEscapeSequence(
        in text: String,
        index: inout String.Index,
        style: inout MobileTerminalGhosttyCellStyle
    ) -> TerminalEscapeAction? {
        var cursor = text.index(after: index)
        guard cursor < text.endIndex else {
            return nil
        }
    
        if text[cursor] == "]" {
            return consumeOSCSequence(in: text, index: &index, cursor: text.index(after: cursor))
                ? TerminalEscapeAction.none
                : nil
        }
    
        guard text[cursor] == "[" else {
            return consumeNonCSISequence(in: text, index: &index, cursor: cursor)
        }
    
        cursor = text.index(after: cursor)
        let parametersStart = cursor
        while cursor < text.endIndex {
            let scalar = text[cursor].unicodeScalars.first?.value ?? 0
            if scalar >= 0x40, scalar <= 0x7E {
                let final = text[cursor]
                let parameters = String(text[parametersStart..<cursor])
                if final == "m" {
                    applySGRParameters(parameters, to: &style)
                }
                index = text.index(after: cursor)
                return terminalEscapeAction(final: final, parameters: parameters)
            }
            cursor = text.index(after: cursor)
        }
    
        return nil
    }
    
    private static func consumeNonCSISequence(
        in text: String,
        index: inout String.Index,
        cursor: String.Index
    ) -> TerminalEscapeAction? {
        var cursor = cursor
        while cursor < text.endIndex {
            let scalar = text[cursor].unicodeScalars.first?.value ?? 0
            if scalar >= 0x30, scalar <= 0x7E {
                index = text.index(after: cursor)
                return TerminalEscapeAction.none
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
    
    private static func terminalEscapeAction(final: Character, parameters: String) -> TerminalEscapeAction {
        guard !parameters.hasPrefix("?") else {
            return .none
        }
    
        let values = parameters
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    
        func value(at index: Int, default defaultValue: Int) -> Int {
            guard values.indices.contains(index), values[index] > 0 else {
                return defaultValue
            }
            return values[index]
        }
    
        func mode(default defaultValue: Int = 0) -> Int {
            guard values.indices.contains(0) else {
                return defaultValue
            }
            return values[0]
        }
    
        switch final {
        case "H", "f":
            return .cursorPosition(
                row: value(at: 0, default: 1) - 1,
                column: value(at: 1, default: 1) - 1
            )
        case "A":
            return .cursorMove(rowDelta: -value(at: 0, default: 1), columnDelta: 0)
        case "B":
            return .cursorMove(rowDelta: value(at: 0, default: 1), columnDelta: 0)
        case "C":
            return .cursorMove(rowDelta: 0, columnDelta: value(at: 0, default: 1))
        case "D":
            return .cursorMove(rowDelta: 0, columnDelta: -value(at: 0, default: 1))
        case "G":
            return .cursorColumn(value(at: 0, default: 1) - 1)
        case "d":
            return .cursorRow(value(at: 0, default: 1) - 1)
        case "J":
            return .eraseDisplay(mode())
        case "K":
            return .eraseLine(mode())
        default:
            return .none
        }
    }
    
    private static func consumeOSCSequence(
        in text: String,
        index: inout String.Index,
        cursor: String.Index
    ) -> Bool {
        var cursor = cursor
        while cursor < text.endIndex {
            if text[cursor] == "\u{0007}" {
                index = text.index(after: cursor)
                return true
            }
            if text[cursor] == "\u{001B}" {
                let next = text.index(after: cursor)
                if next < text.endIndex, text[next] == "\\" {
                    index = text.index(after: next)
                    return true
                }
            }
            cursor = text.index(after: cursor)
        }
        return false
    }
    
    private static func applySGRParameters(
        _ rawParameters: String,
        to style: inout MobileTerminalGhosttyCellStyle
    ) {
        let parameters = sgrParameters(rawParameters)
    
        var index = 0
        while index < parameters.count {
            let parameter = parameters[index].value
            switch parameter {
            case 0:
                style = MobileTerminalGhosttyCellStyle()
            case 1:
                style.bold = true
            case 2:
                style.dim = true
            case 3:
                style.italic = true
            case 4:
                style.underline = underlineStyle(from: parameters[index].subparameters.dropFirst()) ?? .single
            case 21:
                style.underline = .double
            case 22:
                style.bold = false
                style.dim = false
            case 23:
                style.italic = false
            case 24:
                style.underline = .none
            case 7:
                style.inverse = true
            case 27:
                style.inverse = false
            case 30...37:
                style.foreground = xtermColor(index: parameter - 30)
            case 39:
                style.foreground = nil
            case 40...47:
                style.background = xtermColor(index: parameter - 40)
            case 49:
                style.background = nil
            case 90...97:
                style.foreground = xtermColor(index: parameter - 90 + 8)
            case 100...107:
                style.background = xtermColor(index: parameter - 100 + 8)
            case 38, 48, 58:
                let parsed = parseExtendedColor(parameters: parameters, start: index + 1)
                if let color = parsed.color {
                    if parameter == 38 {
                        style.foreground = color
                    } else if parameter == 48 {
                        style.background = color
                    }
                }
                index = parsed.nextIndex - 1
            default:
                break
            }
            index += 1
        }
    }
    
    private struct SGRParameter {
        var value: Int
        var subparameters: [Int]
    }
    
    private static func sgrParameters(_ rawParameters: String) -> [SGRParameter] {
        if rawParameters.isEmpty {
            return [SGRParameter(value: 0, subparameters: [0])]
        }
    
        return rawParameters.split(separator: ";", omittingEmptySubsequences: false).map { group in
            let subparameters = group.split(separator: ":", omittingEmptySubsequences: false)
                .map { Int($0) ?? 0 }
            return SGRParameter(
                value: subparameters.first ?? 0,
                subparameters: subparameters
            )
        }
    }
    
    private static func underlineStyle(
        from rawSubparameters: ArraySlice<Int>
    ) -> MobileTerminalGhosttyUnderline? {
        guard let value = rawSubparameters.first else {
            return nil
        }
        switch value {
        case 0:
            return MobileTerminalGhosttyUnderline.none
        case 1:
            return .single
        case 2:
            return .double
        case 3:
            return .curly
        case 4:
            return .dotted
        case 5:
            return .dashed
        default:
            return nil
        }
    }
    
    private static func parseExtendedColor(
        parameters: [SGRParameter],
        start: Int
    ) -> (color: MobileTerminalGhosttyColor?, nextIndex: Int) {
        guard parameters.indices.contains(start - 1) else {
            return (nil, start)
        }
    
        let introducingParameter = parameters[start - 1]
        if introducingParameter.subparameters.count > 1 {
            return parseExtendedColorSubparameters(
                Array(introducingParameter.subparameters.dropFirst()),
                nextIndex: start
            )
        }
    
        guard parameters.indices.contains(start) else {
            return (nil, start)
        }
    
        switch parameters[start].value {
        case 2:
            guard parameters.indices.contains(start + 3) else {
                return (nil, start + 1)
            }
            return (
                MobileTerminalGhosttyColor(
                    red: UInt8(clamping: parameters[start + 1].value),
                    green: UInt8(clamping: parameters[start + 2].value),
                    blue: UInt8(clamping: parameters[start + 3].value)
                ),
                start + 4
            )
        case 5:
            guard parameters.indices.contains(start + 1) else {
                return (nil, start + 1)
            }
            return (xtermColor(index: parameters[start + 1].value), start + 2)
        default:
            return (nil, start + 1)
        }
    }
    
    private static func parseExtendedColorSubparameters(
        _ subparameters: [Int],
        nextIndex: Int
    ) -> (color: MobileTerminalGhosttyColor?, nextIndex: Int) {
        guard let mode = subparameters.first else {
            return (nil, nextIndex)
        }
        switch mode {
        case 2:
            guard subparameters.count >= 4 else {
                return (nil, nextIndex)
            }
            let redGreenBlue = Array(subparameters.suffix(3))
            guard redGreenBlue.count == 3 else {
                return (nil, nextIndex)
            }
            return (
                MobileTerminalGhosttyColor(
                    red: UInt8(clamping: redGreenBlue[0]),
                    green: UInt8(clamping: redGreenBlue[1]),
                    blue: UInt8(clamping: redGreenBlue[2])
                ),
                nextIndex
            )
        case 5:
            guard subparameters.indices.contains(1) else {
                return (nil, nextIndex)
            }
            return (xtermColor(index: subparameters[1]), nextIndex)
        default:
            return (nil, nextIndex)
        }
    }
    
    private static func xtermColor(index: Int) -> MobileTerminalGhosttyColor {
        let base: [MobileTerminalGhosttyColor] = [
            MobileTerminalGhosttyColor(red: 0, green: 0, blue: 0),
            MobileTerminalGhosttyColor(red: 205, green: 49, blue: 49),
            MobileTerminalGhosttyColor(red: 13, green: 188, blue: 121),
            MobileTerminalGhosttyColor(red: 229, green: 229, blue: 16),
            MobileTerminalGhosttyColor(red: 36, green: 114, blue: 200),
            MobileTerminalGhosttyColor(red: 188, green: 63, blue: 188),
            MobileTerminalGhosttyColor(red: 17, green: 168, blue: 205),
            MobileTerminalGhosttyColor(red: 229, green: 229, blue: 229),
            MobileTerminalGhosttyColor(red: 102, green: 102, blue: 102),
            MobileTerminalGhosttyColor(red: 241, green: 76, blue: 76),
            MobileTerminalGhosttyColor(red: 35, green: 209, blue: 139),
            MobileTerminalGhosttyColor(red: 245, green: 245, blue: 67),
            MobileTerminalGhosttyColor(red: 59, green: 142, blue: 234),
            MobileTerminalGhosttyColor(red: 214, green: 112, blue: 214),
            MobileTerminalGhosttyColor(red: 41, green: 184, blue: 219),
            MobileTerminalGhosttyColor(red: 229, green: 229, blue: 229),
        ]
    
        if base.indices.contains(index) {
            return base[index]
        }
    
        let clamped = max(0, min(index, 255))
        if clamped < base.count {
            return base[clamped]
        }
        if clamped >= 16, clamped <= 231 {
            let value = clamped - 16
            let red = value / 36
            let green = (value % 36) / 6
            let blue = value % 6
            return MobileTerminalGhosttyColor(
                red: xtermColorCubeComponent(red),
                green: xtermColorCubeComponent(green),
                blue: xtermColorCubeComponent(blue)
            )
        }
    
        let gray = UInt8(clamping: 8 + ((clamped - 232) * 10))
        return MobileTerminalGhosttyColor(red: gray, green: gray, blue: gray)
    }
    
    private static func xtermColorCubeComponent(_ component: Int) -> UInt8 {
        component == 0 ? 0 : UInt8(clamping: 55 + (component * 40))
    }
    
    private static func terminalDisplayWidth(of character: Character) -> Int {
        let scalars = Array(character.unicodeScalars)
        guard !scalars.isEmpty else { return 0 }
        if scalars.allSatisfy({ terminalScalarDisplayWidth($0) == 0 }) {
            return 0
        }
        if scalars.contains(where: isEmojiWidthSelector) || scalars.contains(where: isRegionalIndicatorScalar) {
            return 2
        }
        return scalars.contains { terminalScalarDisplayWidth($0) == 2 } ? 2 : 1
    }
    
    private static func terminalScalarDisplayWidth(_ scalar: UnicodeScalar) -> Int {
        let value = scalar.value
        if value == 0 || value == 0x200D || (0xFE00...0xFE0F).contains(value) {
            return 0
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark:
            return 0
        default:
            break
        }
        if isTerminalWideScalar(value) {
            return 2
        }
        return 1
    }
    
    private static func isTerminalWideScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F,
             0x231A...0x231B,
             0x2329...0x232A,
             0x23E9...0x23EC,
             0x23F0,
             0x23F3,
             0x25FD...0x25FE,
             0x2614...0x2615,
             0x2648...0x2653,
             0x267F,
             0x2693,
             0x26A1,
             0x26AA...0x26AB,
             0x26BD...0x26BE,
             0x26C4...0x26C5,
             0x26CE,
             0x26D4,
             0x26EA,
             0x26F2...0x26F3,
             0x26F5,
             0x26FA,
             0x26FD,
             0x2705,
             0x270A...0x270B,
             0x2728,
             0x274C,
             0x274E,
             0x2753...0x2755,
             0x2757,
             0x2795...0x2797,
             0x27B0,
             0x27BF,
             0x2B1B...0x2B1C,
             0x2B50,
             0x2B55,
             0x2E80...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F004,
             0x1F0CF,
             0x1F18E,
             0x1F191...0x1F19A,
             0x1F200...0x1F251,
             0x1F300...0x1FAFF,
             0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
    
    private static func isEmojiWidthSelector(_ scalar: UnicodeScalar) -> Bool {
        scalar.value == 0xFE0F
    }
    
    private static func isRegionalIndicatorScalar(_ scalar: UnicodeScalar) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar.value)
    }
}

extension MobileTerminalGhosttyCell {
    var isSpacer: Bool {
        switch width {
        case .spacerHead, .spacerTail:
            return true
        case .narrow, .wide:
            return false
        }
    }
}
