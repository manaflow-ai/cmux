import Foundation

public struct MobileTerminalGridSize: Codable, Equatable, Sendable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) throws {
        guard columns > 0, rows > 0 else {
            throw MobileTerminalGhosttySnapshotError.invalidGridSize
        }
        self.columns = columns
        self.rows = rows
    }
}

public enum MobileTerminalGhosttyScreen: String, Codable, Equatable, Sendable {
    case primary
    case alternate
}

public struct MobileTerminalGhosttyColor: Codable, Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum MobileTerminalGhosttyUnderline: String, Codable, Equatable, Sendable {
    case none
    case single
    case double
    case curly
    case dotted
    case dashed
}

public enum MobileTerminalGhosttyCellWidth: String, Codable, Equatable, Sendable {
    case narrow
    case wide
    case spacerTail
    case spacerHead
}

public struct MobileTerminalGhosttyCellStyle: Codable, Equatable, Sendable {
    public var foreground: MobileTerminalGhosttyColor?
    public var background: MobileTerminalGhosttyColor?
    public var bold: Bool
    public var italic: Bool
    public var dim: Bool
    public var inverse: Bool
    public var underline: MobileTerminalGhosttyUnderline

    public init(
        foreground: MobileTerminalGhosttyColor? = nil,
        background: MobileTerminalGhosttyColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        dim: Bool = false,
        inverse: Bool = false,
        underline: MobileTerminalGhosttyUnderline = .none
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.italic = italic
        self.dim = dim
        self.inverse = inverse
        self.underline = underline
    }
}

public struct MobileTerminalGhosttyCell: Codable, Equatable, Sendable {
    public var text: String
    public var width: MobileTerminalGhosttyCellWidth
    public var style: MobileTerminalGhosttyCellStyle
    public var hyperlinkURI: String?

    public init(
        text: String = "",
        width: MobileTerminalGhosttyCellWidth = .narrow,
        style: MobileTerminalGhosttyCellStyle = MobileTerminalGhosttyCellStyle(),
        hyperlinkURI: String? = nil
    ) {
        self.text = text
        self.width = width
        self.style = style
        self.hyperlinkURI = hyperlinkURI
    }

    public static let blank = MobileTerminalGhosttyCell()
}

public struct MobileTerminalGhosttyRow: Codable, Equatable, Sendable {
    public var cells: [MobileTerminalGhosttyCell]
    public var isWrapped: Bool

    public init(cells: [MobileTerminalGhosttyCell], isWrapped: Bool = false) {
        self.cells = cells
        self.isWrapped = isWrapped
    }

    public var plainText: String {
        cells.map { cell in
            switch cell.width {
            case .spacerHead, .spacerTail:
                return ""
            case .narrow, .wide:
                return cell.text.isEmpty ? " " : cell.text
            }
        }
        .joined()
    }

    public var trimmedPlainText: String {
        plainText.trimmingTerminalPadding()
    }

    var isVisuallyBlank: Bool {
        trimmedPlainText.isEmpty
    }
}

public struct MobileTerminalGhosttyCursor: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Equatable, Sendable {
        case block
        case hollowBlock
        case bar
        case underline
    }

    public var column: Int
    public var row: Int
    public var isVisible: Bool
    public var style: Style

    public init(
        column: Int,
        row: Int,
        isVisible: Bool = true,
        style: Style = .block
    ) {
        self.column = column
        self.row = row
        self.isVisible = isVisible
        self.style = style
    }
}

private extension String {
    func trimmingTerminalPadding() -> String {
        var result = self
        while result.last == " " || result.last == "\t" {
            result.removeLast()
        }
        return result
    }
}

public struct MobileTerminalGhosttyModes: Codable, Equatable, Sendable {
    public var bracketedPaste: Bool
    public var applicationCursorKeys: Bool
    public var applicationKeypad: Bool
    public var mouseTracking: Bool
    public var cursorVisible: Bool

    public init(
        bracketedPaste: Bool = false,
        applicationCursorKeys: Bool = false,
        applicationKeypad: Bool = false,
        mouseTracking: Bool = false,
        cursorVisible: Bool = true
    ) {
        self.bracketedPaste = bracketedPaste
        self.applicationCursorKeys = applicationCursorKeys
        self.applicationKeypad = applicationKeypad
        self.mouseTracking = mouseTracking
        self.cursorVisible = cursorVisible
    }

    func applyingCursorVisibility(from text: String) -> MobileTerminalGhosttyModes {
        guard let cursorVisible = Self.cursorVisibility(from: text) else {
            return self
        }
        var modes = self
        modes.cursorVisible = cursorVisible
        return modes
    }

    private static func cursorVisibility(from text: String) -> Bool? {
        var searchStart = text.startIndex
        var cursorVisible: Bool?
        let prefix = "\u{001B}[?"

        while let range = text.range(of: prefix, range: searchStart..<text.endIndex) {
            var cursor = range.upperBound
            let parametersStart = cursor

            while cursor < text.endIndex {
                let scalar = text[cursor].unicodeScalars.first?.value ?? 0
                if scalar >= 0x40, scalar <= 0x7E {
                    let final = text[cursor]
                    if final == "h" || final == "l" {
                        let parameters = text[parametersStart..<cursor]
                            .split(separator: ";")
                            .compactMap { Int($0) }
                        if parameters.contains(25) {
                            cursorVisible = final == "h"
                        }
                    }
                    searchStart = text.index(after: cursor)
                    break
                }
                cursor = text.index(after: cursor)
            }

            if cursor >= text.endIndex {
                searchStart = text.endIndex
            }
        }

        return cursorVisible
    }
}

public struct MobileTerminalGhosttySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var terminalID: String
    public var gridSize: MobileTerminalGridSize
    public var activeScreen: MobileTerminalGhosttyScreen
    public var scrollbackRows: [MobileTerminalGhosttyRow]
    public var visibleRows: [MobileTerminalGhosttyRow]
    public var cursor: MobileTerminalGhosttyCursor
    public var modes: MobileTerminalGhosttyModes
    public var streamOffset: UInt64
    public var generatedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        terminalID: String,
        gridSize: MobileTerminalGridSize,
        activeScreen: MobileTerminalGhosttyScreen,
        scrollbackRows: [MobileTerminalGhosttyRow],
        visibleRows: [MobileTerminalGhosttyRow],
        cursor: MobileTerminalGhosttyCursor,
        modes: MobileTerminalGhosttyModes,
        streamOffset: UInt64,
        generatedAt: Date = Date()
    ) throws {
        self.schemaVersion = schemaVersion
        self.terminalID = terminalID
        self.gridSize = gridSize
        self.activeScreen = activeScreen
        self.scrollbackRows = scrollbackRows
        self.visibleRows = visibleRows
        self.cursor = cursor
        self.modes = modes
        self.streamOffset = streamOffset
        self.generatedAt = generatedAt
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MobileTerminalGhosttySnapshotError.unsupportedSchemaVersion(schemaVersion)
        }
        guard gridSize.columns > 0, gridSize.rows > 0 else {
            throw MobileTerminalGhosttySnapshotError.invalidGridSize
        }
        guard visibleRows.count == gridSize.rows else {
            throw MobileTerminalGhosttySnapshotError.invalidVisibleRowCount(
                expected: gridSize.rows,
                actual: visibleRows.count
            )
        }
        try validateRows(scrollbackRows, kind: .scrollback)
        try validateRows(visibleRows, kind: .visible)
        guard (0..<gridSize.columns).contains(cursor.column),
              (0..<gridSize.rows).contains(cursor.row) else {
            throw MobileTerminalGhosttySnapshotError.cursorOutOfBounds
        }
    }

    public func encodedValidatedJSON() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decodeValidatedJSON(_ data: Data) throws -> MobileTerminalGhosttySnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(MobileTerminalGhosttySnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    public var renderedVisibleLines: [String] {
        visibleRows.map(\.trimmedPlainText)
    }

    public static func fixture(
        terminalID: String,
        columns: Int = 32,
        rows: Int = 6,
        scrollbackLines: [String] = [],
        visibleLines: [String],
        activeScreen: MobileTerminalGhosttyScreen = .primary,
        modes: MobileTerminalGhosttyModes = MobileTerminalGhosttyModes(),
        cursor: MobileTerminalGhosttyCursor? = nil,
        streamOffset: UInt64 = 0,
        generatedAt: Date = Date(timeIntervalSince1970: 0)
    ) throws -> MobileTerminalGhosttySnapshot {
        let gridSize = try MobileTerminalGridSize(columns: columns, rows: rows)
        let visible = paddedRows(lines: visibleLines, columns: columns, rows: rows)
        let resolvedCursor = cursor ?? MobileTerminalGhosttyCursor(
            column: min(columns - 1, visibleLines.last?.count ?? 0),
            row: max(0, min(rows - 1, visibleLines.count - 1)),
            isVisible: modes.cursorVisible
        )
        return try MobileTerminalGhosttySnapshot(
            terminalID: terminalID,
            gridSize: gridSize,
            activeScreen: activeScreen,
            scrollbackRows: scrollbackLines.map { row(from: $0, columns: columns) },
            visibleRows: visible,
            cursor: resolvedCursor,
            modes: modes,
            streamOffset: streamOffset,
            generatedAt: generatedAt
        )
    }

    public static func fromGhosttyText(
        terminalID: String,
        columns: Int,
        rows: Int,
        scrollbackText: String?,
        viewportText: String,
        maxScrollbackRows: Int? = nil,
        activeScreen: MobileTerminalGhosttyScreen = .primary,
        modes: MobileTerminalGhosttyModes = MobileTerminalGhosttyModes(),
        cursor: MobileTerminalGhosttyCursor? = nil,
        streamOffset: UInt64 = 0,
        generatedAt: Date = Date()
    ) throws -> MobileTerminalGhosttySnapshot {
        // This rehydrates styles from Ghostty VT/ANSI exports. It is not a
        // true Ghostty grid exporter: plain text snapshots have already lost
        // cell colors, width metadata, hyperlinks, and unsupported attributes.
        let visibleGrid = styledGrid(from: viewportText, columns: columns)
        var scrollbackRows = styledRows(from: scrollbackText ?? "", columns: columns)
        if let maxScrollbackRows {
            scrollbackRows = Array(scrollbackRows.suffix(max(0, maxScrollbackRows)))
        }
        let resolvedModes = modes.applyingCursorVisibility(from: viewportText)
        let resolvedCursor = cursor.map { liveCursor in
            MobileTerminalGhosttyCursor(
                column: liveCursor.column,
                row: liveCursor.row,
                isVisible: liveCursor.isVisible && resolvedModes.cursorVisible,
                style: liveCursor.style
            )
        } ?? MobileTerminalGhosttyCursor(
            column: min(max(visibleGrid.cursorColumn, 0), max(columns - 1, 0)),
            row: min(max(visibleGrid.cursorRow, 0), max(rows - 1, 0)),
            isVisible: resolvedModes.cursorVisible
        )
        return try MobileTerminalGhosttySnapshot(
            terminalID: terminalID,
            gridSize: MobileTerminalGridSize(columns: columns, rows: rows),
            activeScreen: activeScreen,
            scrollbackRows: scrollbackRows,
            visibleRows: paddedRows(
                rows: visibleGrid.rows,
                columns: columns,
                count: rows,
                cursorRow: resolvedCursor.isVisible ? resolvedCursor.row : nil,
                sourceCursorRow: visibleGrid.cursorRow
            ),
            cursor: resolvedCursor,
            modes: resolvedModes,
            streamOffset: streamOffset,
            generatedAt: generatedAt
        )
    }

    private enum RowKind {
        case scrollback
        case visible
    }

    private func validateRows(_ rows: [MobileTerminalGhosttyRow], kind: RowKind) throws {
        for (index, row) in rows.enumerated() where row.cells.count != gridSize.columns {
            switch kind {
            case .scrollback:
                throw MobileTerminalGhosttySnapshotError.invalidScrollbackRowWidth(
                    row: index,
                    expected: gridSize.columns,
                    actual: row.cells.count
                )
            case .visible:
                throw MobileTerminalGhosttySnapshotError.invalidVisibleRowWidth(
                    row: index,
                    expected: gridSize.columns,
                    actual: row.cells.count
                )
            }
        }
    }

    private static func paddedRows(
        lines: [String],
        columns: Int,
        rows: Int
    ) -> [MobileTerminalGhosttyRow] {
        var padded = lines.prefix(rows).map { row(from: $0, columns: columns) }
        while padded.count < rows {
            padded.append(row(from: "", columns: columns))
        }
        return padded
    }

    private static func paddedRows(
        rows: [MobileTerminalGhosttyRow],
        columns: Int,
        count: Int,
        cursorRow: Int? = nil,
        sourceCursorRow: Int? = nil
    ) -> [MobileTerminalGhosttyRow] {
        var padded = visibleRows(
            from: rows,
            count: count,
            cursorRow: cursorRow,
            sourceCursorRow: sourceCursorRow
        )
        if let cursorRow {
            padded = rowsAlignedToCursor(
                rows: padded,
                columns: columns,
                count: count,
                cursorRow: cursorRow
            )
        }
        while padded.count < count {
            padded.append(row(from: "", columns: columns))
        }
        return padded
    }

    private static func visibleRows(
        from rows: [MobileTerminalGhosttyRow],
        count: Int,
        cursorRow: Int?,
        sourceCursorRow: Int?
    ) -> [MobileTerminalGhosttyRow] {
        guard count > 0, rows.count > count else {
            return Array(rows.prefix(count))
        }

        let maxStartIndex = rows.count - count
        if let cursorRow,
           let sourceCursorRow {
            let startIndex = sourceCursorRow - cursorRow
            if (0...maxStartIndex).contains(startIndex) {
                return Array(rows[startIndex..<(startIndex + count)])
            }
        }

        return Array(rows.suffix(count))
    }

    private static func rowsAlignedToCursor(
        rows: [MobileTerminalGhosttyRow],
        columns: Int,
        count: Int,
        cursorRow: Int
    ) -> [MobileTerminalGhosttyRow] {
        guard count > 0,
              let firstContentRow = rows.firstIndex(where: { !$0.isVisuallyBlank }),
              firstContentRow == 0,
              let lastContentRow = rows.lastIndex(where: { !$0.isVisuallyBlank }),
              cursorRow - lastContentRow > 1 else {
            return rows
        }

        let blankRowsToInsert = min(cursorRow - lastContentRow, max(0, count - 1))
        guard blankRowsToInsert > 0 else {
            return rows
        }

        let shiftedRows = Array(
            repeating: row(from: "", columns: columns),
            count: blankRowsToInsert
        ) + rows
        return Array(shiftedRows.prefix(count))
    }

    private static func row(from line: String, columns: Int) -> MobileTerminalGhosttyRow {
        var cells = Array(line).prefix(columns).map { character in
            MobileTerminalGhosttyCell(text: String(character))
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

    private struct StyledTerminalGrid {
        var rows: [MobileTerminalGhosttyRow]
        var cursorColumn: Int
        var cursorRow: Int
    }

    private static func styledRows(from text: String, columns: Int) -> [MobileTerminalGhosttyRow] {
        styledGrid(from: text, columns: columns).rows
    }

    private static func styledGrid(from text: String, columns: Int) -> StyledTerminalGrid {
        let resolvedColumns = max(1, columns)
        let text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !text.isEmpty else {
            return StyledTerminalGrid(rows: [], cursorColumn: 0, cursorRow: 0)
        }
        let wrapsOverflow = text.contains("\u{001B}")

        var rows: [[MobileTerminalGhosttyCell]] = [[]]
        var wrappedRowIndices = Set<Int>()
        var row = 0
        var column = 0
        var wrapPending = false
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
                moveCursor(row: newRow, column: newColumn)
            case let .cursorMove(rowDelta, columnDelta):
                moveCursor(row: row + rowDelta, column: column + columnDelta)
            case let .cursorColumn(newColumn):
                moveCursor(row: row, column: newColumn)
            case let .cursorRow(newRow):
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
                writeCell(MobileTerminalGhosttyCell(text: String(character), style: style))
            }
        }

        if text.hasSuffix("\n"), rows.last?.isEmpty == true {
            rows.removeLast()
        }

        return StyledTerminalGrid(
            rows: normalizedRows(),
            cursorColumn: min(max(column, 0), resolvedColumns - 1),
            cursorRow: max(row, 0)
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
            index = text.index(after: cursor)
            return TerminalEscapeAction.none
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
}

public enum MobileTerminalGhosttySnapshotError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidGridSize
    case invalidVisibleRowCount(expected: Int, actual: Int)
    case invalidVisibleRowWidth(row: Int, expected: Int, actual: Int)
    case invalidScrollbackRowWidth(row: Int, expected: Int, actual: Int)
    case cursorOutOfBounds
}
