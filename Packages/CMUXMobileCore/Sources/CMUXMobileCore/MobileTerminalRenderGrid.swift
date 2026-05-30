import Foundation

public enum MobileTerminalRenderGridError: Error, Equatable, Sendable {
    case invalidFormat(String)
    case invalidDimensions(columns: Int, rows: Int)
    case invalidRow(Int)
    case invalidColumn(Int)
}

public struct MobileTerminalRenderGridFrame: Codable, Equatable, Sendable {
    public static let currentFormat = "cmux.render-grid.v1"

    public var format: String
    public var surfaceID: String
    public var stateSeq: UInt64
    public var columns: Int
    public var rows: Int
    public var cursor: Cursor?
    public var styles: [Style]
    public var rowSpans: [RowSpan]

    public init(
        format: String = Self.currentFormat,
        surfaceID: String,
        stateSeq: UInt64,
        columns: Int,
        rows: Int,
        cursor: Cursor? = nil,
        styles: [Style] = [.default],
        rowSpans: [RowSpan]
    ) throws {
        guard format == Self.currentFormat else {
            throw MobileTerminalRenderGridError.invalidFormat(format)
        }
        guard columns > 0, rows > 0 else {
            throw MobileTerminalRenderGridError.invalidDimensions(columns: columns, rows: rows)
        }
        for span in rowSpans {
            guard (0..<rows).contains(span.row) else {
                throw MobileTerminalRenderGridError.invalidRow(span.row)
            }
            guard (0..<columns).contains(span.column) else {
                throw MobileTerminalRenderGridError.invalidColumn(span.column)
            }
        }
        self.format = format
        self.surfaceID = surfaceID
        self.stateSeq = stateSeq
        self.columns = columns
        self.rows = rows
        self.cursor = cursor
        self.styles = styles.isEmpty ? [.default] : styles
        self.rowSpans = rowSpans
    }

    public static func fromPlainRows(
        surfaceID: String,
        stateSeq: UInt64,
        columns: Int,
        rows: Int,
        text: String,
        cursor: Cursor? = nil
    ) throws -> MobileTerminalRenderGridFrame {
        let lines = normalizedRows(from: text, maxRows: rows)
        let spans = lines.enumerated().compactMap { row, line -> RowSpan? in
            let trimmed = trimmingTrailingGridBlanks(line)
            guard !trimmed.isEmpty else { return nil }
            return RowSpan(row: row, column: 0, styleID: 0, text: trimmed)
        }
        return try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            columns: columns,
            rows: rows,
            cursor: cursor,
            rowSpans: spans
        )
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
        var bytes = Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)
        for span in rowSpans {
            bytes.append(Data("\u{1B}[\(span.row + 1);\(span.column + 1)H".utf8))
            bytes.append(Self.vtPrintableBytes(span.text))
        }
        if let cursor {
            bytes.append(Data("\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H".utf8))
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

    enum CodingKeys: String, CodingKey {
        case format
        case surfaceID = "surface_id"
        case stateSeq = "state_seq"
        case columns
        case rows
        case cursor
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

        enum CodingKeys: String, CodingKey {
            case row
            case column
            case styleID = "style_id"
            case text
        }
    }
}
