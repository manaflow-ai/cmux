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
        let visibleLines = terminalLines(from: viewportText)
        var scrollbackLines = terminalLines(from: scrollbackText ?? "")
        if let maxScrollbackRows {
            scrollbackLines = Array(scrollbackLines.suffix(max(0, maxScrollbackRows)))
        }
        let resolvedCursor = cursor ?? MobileTerminalGhosttyCursor(
            column: 0,
            row: max(0, rows - 1),
            isVisible: modes.cursorVisible
        )
        return try MobileTerminalGhosttySnapshot(
            terminalID: terminalID,
            gridSize: MobileTerminalGridSize(columns: columns, rows: rows),
            activeScreen: activeScreen,
            scrollbackRows: scrollbackLines.map { row(from: $0, columns: columns) },
            visibleRows: paddedRows(lines: visibleLines, columns: columns, rows: rows),
            cursor: resolvedCursor,
            modes: modes,
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
}

public enum MobileTerminalGhosttySnapshotError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidGridSize
    case invalidVisibleRowCount(expected: Int, actual: Int)
    case invalidVisibleRowWidth(row: Int, expected: Int, actual: Int)
    case invalidScrollbackRowWidth(row: Int, expected: Int, actual: Int)
    case cursorOutOfBounds
}
