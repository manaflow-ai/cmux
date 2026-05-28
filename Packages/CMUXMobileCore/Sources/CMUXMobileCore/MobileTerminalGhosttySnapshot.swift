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

    public var hasExplicitCellStyles: Bool {
        Self.rowsHaveExplicitCellStyles(visibleRows) || Self.rowsHaveExplicitCellStyles(scrollbackRows)
    }

    public func reusingExplicitCellStyles(from previous: MobileTerminalGhosttySnapshot) -> MobileTerminalGhosttySnapshot {
        guard terminalID == previous.terminalID,
              gridSize == previous.gridSize else {
            return self
        }

        var snapshot = self
        snapshot.visibleRows = Self.rowsByReusingExplicitCellStyles(
            visibleRows,
            previousRows: previous.visibleRows
        )
        snapshot.scrollbackRows = Self.rowsByReusingExplicitCellStyles(
            scrollbackRows,
            previousRows: previous.scrollbackRows
        )
        return snapshot
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
        let cursorRow = max(0, min(rows - 1, visibleLines.count - 1))
        let cursorSourceRow = visible.indices.contains(cursorRow) ? visible[cursorRow] : nil
        let resolvedCursor = cursor ?? MobileTerminalGhosttyCursor(
            column: cursorColumn(from: cursorSourceRow, columns: columns),
            row: cursorRow,
            isVisible: modes.cursorVisible
        )
        return try MobileTerminalGhosttySnapshot(
            terminalID: terminalID,
            gridSize: gridSize,
            activeScreen: activeScreen,
            scrollbackRows: scrollbackLines.map { MobileTerminalGhosttyVTParser.row(from: $0, columns: columns) },
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
        let visibleGrid = MobileTerminalGhosttyVTParser.styledGrid(from: viewportText, columns: columns)
        let sourceCursorRow = min(
            max(visibleGrid.cursorRow, 0),
            max(visibleGrid.rows.count - 1, 0)
        )
        let viewportCursorRow = visibleGrid.viewportCursorRow
        var scrollbackRows = MobileTerminalGhosttyVTParser.styledRows(from: scrollbackText ?? "", columns: columns)
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
            row: min(max(viewportCursorRow, 0), max(rows - 1, 0)),
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
                sourceCursorRow: sourceCursorRow,
                alignRowsToCursor: visibleGrid.usesAbsoluteCursorAddressing
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

    private static func rowsHaveExplicitCellStyles(_ rows: [MobileTerminalGhosttyRow]) -> Bool {
        rows.contains { row in
            row.cells.contains { cell in
                cell.style != MobileTerminalGhosttyCellStyle()
            }
        }
    }

    private static func rowsByReusingExplicitCellStyles(
        _ rows: [MobileTerminalGhosttyRow],
        previousRows: [MobileTerminalGhosttyRow]
    ) -> [MobileTerminalGhosttyRow] {
        guard rows.count == previousRows.count else {
            return rows
        }

        return rows.indices.map { rowIndex in
            let row = rows[rowIndex]
            let previousRow = previousRows[rowIndex]
            guard row.cells.count == previousRow.cells.count else {
                return row
            }
            guard shouldReuseExplicitCellStyles(in: row, previousRow: previousRow) else {
                return row
            }

            var cells = row.cells
            for cellIndex in cells.indices {
                let previousCell = previousRow.cells[cellIndex]
                guard cells[cellIndex].style == MobileTerminalGhosttyCellStyle(),
                      previousCell.style != MobileTerminalGhosttyCellStyle(),
                      cells[cellIndex].text == previousCell.text,
                      cells[cellIndex].width == previousCell.width else {
                    continue
                }
                cells[cellIndex].style = previousCell.style
                if cells[cellIndex].hyperlinkURI == nil, !cells[cellIndex].text.isEmpty {
                    cells[cellIndex].hyperlinkURI = previousCell.hyperlinkURI
                }
            }
            return MobileTerminalGhosttyRow(cells: cells, isWrapped: row.isWrapped)
        }
    }

    private static func shouldReuseExplicitCellStyles(
        in row: MobileTerminalGhosttyRow,
        previousRow: MobileTerminalGhosttyRow
    ) -> Bool {
        let text = row.trimmedPlainText
        let previousText = previousRow.trimmedPlainText
        if text.isEmpty || previousText.isEmpty {
            return text == previousText
        }
        return text.hasPrefix(previousText) || previousText.hasPrefix(text)
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
        var padded = lines.prefix(rows).map { MobileTerminalGhosttyVTParser.row(from: $0, columns: columns) }
        while padded.count < rows {
            padded.append(MobileTerminalGhosttyVTParser.row(from: "", columns: columns))
        }
        return padded
    }

    private static func paddedRows(
        rows: [MobileTerminalGhosttyRow],
        columns: Int,
        count: Int,
        cursorRow: Int? = nil,
        sourceCursorRow: Int? = nil,
        alignRowsToCursor: Bool = false
    ) -> [MobileTerminalGhosttyRow] {
        var padded = visibleRows(
            from: rows,
            count: count,
            cursorRow: cursorRow,
            sourceCursorRow: sourceCursorRow
        )
        if alignRowsToCursor, let cursorRow {
            padded = rowsAlignedToCursor(
                rows: padded,
                columns: columns,
                count: count,
                cursorRow: cursorRow
            )
        }
        while padded.count < count {
            padded.append(MobileTerminalGhosttyVTParser.row(from: "", columns: columns))
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
            repeating: MobileTerminalGhosttyVTParser.row(from: "", columns: columns),
            count: blankRowsToInsert
        ) + rows
        return Array(shiftedRows.prefix(count))
    }

    private static func cursorColumn(from row: MobileTerminalGhosttyRow?, columns: Int) -> Int {
        guard let row, columns > 0 else { return 0 }
        var lastOccupiedColumn = 0
        for (index, cell) in row.cells.enumerated() {
            guard !cell.text.isEmpty, !cell.isSpacer else { continue }
            switch cell.width {
            case .wide:
                lastOccupiedColumn = max(lastOccupiedColumn, index + 2)
            case .narrow:
                lastOccupiedColumn = max(lastOccupiedColumn, index + 1)
            case .spacerHead, .spacerTail:
                break
            }
        }
        return min(columns - 1, lastOccupiedColumn)
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
