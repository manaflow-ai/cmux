import Foundation

public enum MobileTerminalRenderGridError: Error, Equatable, Sendable {
    case invalidFormat(String)
    case invalidDimensions(columns: Int, rows: Int)
    case invalidRow(Int)
    case invalidColumn(Int)
    case invalidCursor(row: Int, column: Int)
    case invalidStyleID(Int)
    case invalidSpanWidth(row: Int, column: Int, width: Int, columns: Int)
}

public struct MobileTerminalRenderGridFrame: Codable, Equatable, Sendable {
    public static let currentFormat = "cmux.render-grid.v1"

    public var format: String
    public var surfaceID: String
    public var stateSeq: UInt64
    public var columns: Int
    public var rows: Int
    public var cursor: Cursor?
    public var full: Bool
    public var clearedRows: [Int]
    public var styles: [Style]
    public var rowSpans: [RowSpan]

    public init(
        format: String = Self.currentFormat,
        surfaceID: String,
        stateSeq: UInt64,
        columns: Int,
        rows: Int,
        cursor: Cursor? = nil,
        full: Bool = true,
        clearedRows: [Int] = [],
        styles: [Style] = [.default],
        rowSpans: [RowSpan]
    ) throws {
        guard format == Self.currentFormat else {
            throw MobileTerminalRenderGridError.invalidFormat(format)
        }
        guard columns > 0, rows > 0 else {
            throw MobileTerminalRenderGridError.invalidDimensions(columns: columns, rows: rows)
        }
        if let cursor,
           !(0..<rows).contains(cursor.row) || !(0..<columns).contains(cursor.column) {
            throw MobileTerminalRenderGridError.invalidCursor(row: cursor.row, column: cursor.column)
        }
        for row in clearedRows {
            guard (0..<rows).contains(row) else {
                throw MobileTerminalRenderGridError.invalidRow(row)
            }
        }
        let resolvedStyles = styles.isEmpty ? [.default] : styles
        let styleIDs = Set(resolvedStyles.map(\.id))
        for span in rowSpans {
            guard (0..<rows).contains(span.row) else {
                throw MobileTerminalRenderGridError.invalidRow(span.row)
            }
            guard (0..<columns).contains(span.column) else {
                throw MobileTerminalRenderGridError.invalidColumn(span.column)
            }
            guard styleIDs.contains(span.styleID) else {
                throw MobileTerminalRenderGridError.invalidStyleID(span.styleID)
            }
            let width = span.gridCellWidth
            guard width > 0, span.column + width <= columns else {
                throw MobileTerminalRenderGridError.invalidSpanWidth(
                    row: span.row,
                    column: span.column,
                    width: width,
                    columns: columns
                )
            }
        }
        self.format = format
        self.surfaceID = surfaceID
        self.stateSeq = stateSeq
        self.columns = columns
        self.rows = rows
        self.cursor = cursor
        self.full = full
        self.clearedRows = full ? [] : Array(Set(clearedRows).sorted())
        self.styles = resolvedStyles
        self.rowSpans = rowSpans
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        let surfaceID = try container.decode(String.self, forKey: .surfaceID)
        let stateSeq = try container.decode(UInt64.self, forKey: .stateSeq)
        let columns = try container.decode(Int.self, forKey: .columns)
        let rows = try container.decode(Int.self, forKey: .rows)
        let cursor = try container.decodeIfPresent(Cursor.self, forKey: .cursor)
        let full = try container.decodeIfPresent(Bool.self, forKey: .full) ?? true
        let clearedRows = try container.decodeIfPresent([Int].self, forKey: .clearedRows) ?? []
        let styles = try container.decodeIfPresent([Style].self, forKey: .styles) ?? [.default]
        let rowSpans = try container.decode([RowSpan].self, forKey: .rowSpans)
        try self.init(
            format: format,
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            columns: columns,
            rows: rows,
            cursor: cursor,
            full: full,
            clearedRows: clearedRows,
            styles: styles,
            rowSpans: rowSpans
        )
    }

    public static func fromPlainRows(
        surfaceID: String,
        stateSeq: UInt64,
        columns: Int,
        rows: Int,
        text: String,
        cursor: Cursor? = nil,
        full: Bool = true,
        changedRows: Set<Int>? = nil
    ) throws -> MobileTerminalRenderGridFrame {
        let lines = normalizedRows(from: text, maxRows: rows)
        let includedRows = changedRows ?? Set(0..<rows)
        let spans = lines.enumerated().compactMap { row, line -> RowSpan? in
            guard includedRows.contains(row) else { return nil }
            let trimmed = trimmingTrailingGridBlanks(line)
            guard !trimmed.isEmpty else { return nil }
            return RowSpan(
                row: row,
                column: 0,
                styleID: 0,
                text: clippedToColumns(trimmed, columns: columns)
            )
        }
        return try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            columns: columns,
            rows: rows,
            cursor: cursor,
            full: full,
            clearedRows: full ? [] : Array(includedRows.sorted()),
            rowSpans: spans
        )
    }

    public static func normalizedPlainRows(from text: String, maxRows: Int) -> [String] {
        normalizedRows(from: text, maxRows: maxRows)
    }

    public func jsonObject() throws -> [String: Any] {
        let data = try JSONEncoder().encode(self)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    public static func decodeJSONObject(_ object: Any) throws -> MobileTerminalRenderGridFrame {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data)
    }

    public func vtReplacementBytes() -> Data {
        vtPatchBytes()
    }

    public func vtPatchBytes() -> Data {
        var bytes = Data()
        if full {
            bytes.append(Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8))
        } else {
            let rowsToClear = Set(clearedRows).union(rowSpans.map(\.row)).sorted()
            for row in rowsToClear {
                bytes.append(Data("\u{1B}[\(row + 1);1H\u{1B}[2K".utf8))
            }
        }
        var stylesByID: [Int: Style] = [:]
        for style in styles {
            stylesByID[style.id] = style
        }
        var activeStyleID: Int?
        for span in rowSpans {
            bytes.append(Data("\u{1B}[\(span.row + 1);\(span.column + 1)H".utf8))
            if activeStyleID != span.styleID,
               let style = stylesByID[span.styleID] {
                bytes.append(Self.sgrBytes(for: style))
                activeStyleID = span.styleID
            }
            bytes.append(Self.vtPrintableBytes(span.text))
        }
        if activeStyleID != nil {
            bytes.append(Data("\u{1B}[0m".utf8))
        }
        if let cursor {
            if cursor.visible {
                bytes.append(Data("\u{1B}[?25h\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H".utf8))
            } else {
                bytes.append(Data("\u{1B}[?25l".utf8))
            }
        }
        return bytes
    }

    private static func normalizedRows(from text: String, maxRows: Int) -> [String] {
        var normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        if normalized.count > maxRows, normalized.last?.isEmpty == true {
            normalized.removeLast()
        }
        if normalized.count > maxRows {
            normalized = Array(normalized.prefix(maxRows))
        }
        while normalized.count < maxRows {
            normalized.append("")
        }
        return normalized
    }

    private static func trimmingTrailingGridBlanks(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let space = UnicodeScalar(" ")
        let tab = UnicodeScalar("\t")
        var end = scalars.endIndex
        while end > scalars.startIndex {
            let previous = scalars.index(before: end)
            guard scalars[previous] == space || scalars[previous] == tab else { break }
            end = previous
        }
        return String(String.UnicodeScalarView(scalars[..<end]))
    }

    private static func clippedToColumns(_ text: String, columns: Int) -> String {
        guard text.count > columns else { return text }
        return String(text.prefix(columns))
    }

    private static func vtPrintableBytes(_ text: String) -> Data {
        var output = String()
        output.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x20...0x10FFFF where scalar.value != 0x7F:
                output.unicodeScalars.append(scalar)
            default:
                output.append(" ")
            }
        }
        return Data(output.utf8)
    }

    private static func sgrBytes(for style: Style) -> Data {
        var codes = ["0"]
        if style.bold { codes.append("1") }
        if style.italic { codes.append("3") }
        if style.underline { codes.append("4") }
        if let foreground = rgbComponents(style.foreground) {
            codes.append("38;2;\(foreground.red);\(foreground.green);\(foreground.blue)")
        }
        if let background = rgbComponents(style.background) {
            codes.append("48;2;\(background.red);\(background.green);\(background.blue)")
        }
        return Data("\u{1B}[\(codes.joined(separator: ";"))m".utf8)
    }

    private static func rgbComponents(_ value: String?) -> (red: Int, green: Int, blue: Int)? {
        guard var value else { return nil }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let raw = Int(value, radix: 16) else { return nil }
        return ((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
    }

    enum CodingKeys: String, CodingKey {
        case format
        case surfaceID = "surface_id"
        case stateSeq = "state_seq"
        case columns
        case rows
        case cursor
        case full
        case clearedRows = "cleared_rows"
        case styles
        case rowSpans = "row_spans"
    }

    public struct Cursor: Codable, Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var visible: Bool

        public init(row: Int, column: Int, visible: Bool = true) {
            self.row = row
            self.column = column
            self.visible = visible
        }
    }

    public struct Style: Codable, Equatable, Sendable {
        public static let `default` = Style(id: 0)

        public var id: Int
        public var foreground: String?
        public var background: String?
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool

        public init(
            id: Int,
            foreground: String? = nil,
            background: String? = nil,
            bold: Bool = false,
            italic: Bool = false,
            underline: Bool = false
        ) {
            self.id = id
            self.foreground = foreground
            self.background = background
            self.bold = bold
            self.italic = italic
            self.underline = underline
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(Int.self, forKey: .id)
            self.foreground = try container.decodeIfPresent(String.self, forKey: .foreground)
            self.background = try container.decodeIfPresent(String.self, forKey: .background)
            self.bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
            self.italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
            self.underline = try container.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        }
    }

    public struct RowSpan: Codable, Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var styleID: Int
        public var text: String

        public init(row: Int, column: Int, styleID: Int = 0, text: String) {
            self.row = row
            self.column = column
            self.styleID = styleID
            self.text = text
        }

        fileprivate var gridCellWidth: Int {
            text.count
        }

        enum CodingKeys: String, CodingKey {
            case row
            case column
            case styleID = "style_id"
            case text
        }
    }
}
