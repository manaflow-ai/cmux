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
    /// Which screen the snapshot represents. The alternate screen is restored
    /// with `?1049h` so a TUI keeps real alt-screen semantics (exiting it
    /// returns to the primary screen) instead of being painted onto primary.
    public var activeScreen: Screen
    /// Non-default DEC/ANSI modes to restore on a full snapshot (mouse
    /// tracking, bracketed paste, application cursor keys, origin, autowrap,
    /// etc.). Empty for delta frames.
    public var modes: [ModeSetting]
    /// Dynamic default foreground/background/cursor colors (OSC 10/11/12),
    /// `nil` when the terminal still uses its configured defaults.
    public var terminalForeground: String?
    public var terminalBackground: String?
    public var terminalCursorColor: String?
    /// Count of scrollback lines carried in ``scrollbackSpans`` (rows above the
    /// visible viewport, oldest first). Only meaningful on a full primary-screen
    /// snapshot; the alternate screen has no scrollback.
    public var scrollbackRows: Int
    /// Styled spans for the scrollback lines, row index `0..<scrollbackRows`
    /// (oldest first). Reuses ``styles`` by `styleID`.
    public var scrollbackSpans: [RowSpan]
    /// Process-stable hash of the **complete** resulting viewport grid, stamped
    /// by the producer onto every emitted frame (full or delta). The consumer
    /// recomputes ``gridContentHash()`` from its own applied grid and requests a
    /// full keyframe when it disagrees, so a delta that silently misses a
    /// cleared/changed row self-corrects within one frame instead of staying
    /// stale forever. `nil` on frames from a producer that predates this field.
    public var gridHash: UInt64?

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
        rowSpans: [RowSpan],
        activeScreen: Screen = .primary,
        modes: [ModeSetting] = [],
        terminalForeground: String? = nil,
        terminalBackground: String? = nil,
        terminalCursorColor: String? = nil,
        scrollbackRows: Int = 0,
        scrollbackSpans: [RowSpan] = [],
        gridHash: UInt64? = nil
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
        let resolvedScrollbackRows = max(0, scrollbackRows)
        for span in scrollbackSpans {
            guard (0..<resolvedScrollbackRows).contains(span.row) else {
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
        self.activeScreen = activeScreen
        self.modes = modes
        self.terminalForeground = terminalForeground
        self.terminalBackground = terminalBackground
        self.terminalCursorColor = terminalCursorColor
        self.scrollbackRows = full ? resolvedScrollbackRows : 0
        self.scrollbackSpans = full ? scrollbackSpans : []
        self.gridHash = gridHash
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
        let activeScreen = try container.decodeIfPresent(Screen.self, forKey: .activeScreen) ?? .primary
        let modes = try container.decodeIfPresent([ModeSetting].self, forKey: .modes) ?? []
        let terminalForeground = try container.decodeIfPresent(String.self, forKey: .terminalForeground)
        let terminalBackground = try container.decodeIfPresent(String.self, forKey: .terminalBackground)
        let terminalCursorColor = try container.decodeIfPresent(String.self, forKey: .terminalCursorColor)
        let scrollbackRows = try container.decodeIfPresent(Int.self, forKey: .scrollbackRows) ?? 0
        let scrollbackSpans = try container.decodeIfPresent([RowSpan].self, forKey: .scrollbackSpans) ?? []
        let gridHash = try container.decodeIfPresent(UInt64.self, forKey: .gridHash)
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
            rowSpans: rowSpans,
            activeScreen: activeScreen,
            modes: modes,
            terminalForeground: terminalForeground,
            terminalBackground: terminalBackground,
            terminalCursorColor: terminalCursorColor,
            scrollbackRows: scrollbackRows,
            scrollbackSpans: scrollbackSpans,
            gridHash: gridHash
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

    public func plainRows() -> [String] {
        var rows = Array(repeating: "", count: self.rows)
        for span in rowSpans.sorted(by: { lhs, rhs in
            lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
        }) {
            guard rows.indices.contains(span.row) else { continue }
            let currentWidth = rows[span.row].count
            if currentWidth < span.column {
                rows[span.row].append(String(repeating: " ", count: span.column - currentWidth))
            }
            rows[span.row].append(span.text)
            let textWidth = span.text.count
            let padWidth = max(0, span.gridCellWidth - textWidth)
            if padWidth > 0 {
                rows[span.row].append(String(repeating: " ", count: padWidth))
            }
        }
        return rows
    }

    /// A per-row signature capturing both text **and resolved styling**, used
    /// to detect which rows changed between two full snapshots.
    ///
    /// Unlike ``plainRows()`` this changes when only a cell's style changes
    /// (for example a character typed over a dimmed shell autosuggestion, where
    /// the text is identical but the cell flips from faint to normal), so a
    /// style-only update is not dropped from the delta. The style is resolved
    /// to its visual attributes rather than keyed by ``Style/id``, because the
    /// producer reassigns style ids on every export.
    public func rowSignatures() -> [String] {
        var stylesByID: [Int: Style] = [:]
        for style in styles {
            stylesByID[style.id] = style
        }
        var spansByRow: [Int: [RowSpan]] = [:]
        for span in rowSpans {
            spansByRow[span.row, default: []].append(span)
        }
        var signatures = Array(repeating: "", count: rows)
        for row in 0..<rows {
            guard let spans = spansByRow[row] else { continue }
            signatures[row] = spans
                .sorted { $0.column < $1.column }
                .map { span in
                    let style = stylesByID[span.styleID] ?? .default
                    return "\(span.column):\(span.gridCellWidth):\(Self.styleSignature(style)):\(span.text)"
                }
                .joined(separator: "\u{1F}")
        }
        return signatures
    }

    private static func styleSignature(_ style: Style) -> String {
        let flags = [
            style.bold, style.faint, style.italic, style.underline, style.blink,
            style.inverse, style.invisible, style.strikethrough, style.overline,
        ].map { $0 ? "1" : "0" }.joined()
        return "\(style.foreground ?? "-")/\(style.background ?? "-")/\(flags)"
    }

    /// A process-stable FNV-1a-64 hash of the **complete** viewport grid content
    /// (dimensions plus every row's resolved text and styling). Unlike Swift's
    /// `Hasher` (randomly seeded per process), this is deterministic across
    /// processes and devices, so the producer's hash of its authoritative grid
    /// and the consumer's hash of its applied grid are directly comparable.
    ///
    /// Computed from ``rowSignatures()``, so it is only meaningful on a **full**
    /// frame describing the whole viewport. Cursor position and scrollback are
    /// intentionally excluded: this detects *content* divergence (stale or blank
    /// cells), not cursor movement.
    public func gridContentHash() -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        func feed(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        for byte in "\(columns)x\(rows)".utf8 { feed(byte) }
        for signature in rowSignatures() {
            feed(0x0A)
            for byte in signature.utf8 { feed(byte) }
        }
        return hash
    }

    /// Returns a copy of this frame stamped with `hash` as its ``gridHash``. The
    /// producer computes ``gridContentHash()`` on its authoritative full
    /// snapshot and stamps it onto the frame it actually emits (full or delta).
    public func stampingGridHash(_ hash: UInt64) -> MobileTerminalRenderGridFrame {
        var copy = self
        copy.gridHash = hash
        return copy
    }

    /// Whether the consumer must request a full keyframe after applying this
    /// frame, given the ``gridContentHash()`` of its own resulting grid.
    ///
    /// Returns `false` when the frame carries no ``gridHash`` (a producer that
    /// predates the field), so the detector degrades to today's behavior rather
    /// than looping on keyframes it cannot verify.
    public func divergesFromAppliedGrid(hash appliedHash: UInt64) -> Bool {
        guard let gridHash else { return false }
        return gridHash != appliedHash
    }

    public func filteredRows(_ includedRows: Set<Int>, full: Bool) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            columns: columns,
            rows: rows,
            cursor: cursor,
            full: full,
            clearedRows: full ? [] : Array(includedRows.sorted()),
            styles: styles,
            rowSpans: rowSpans.filter { includedRows.contains($0.row) },
            // Full-state restore data only applies to a full snapshot; a delta
            // frame just clears and repaints the changed viewport rows.
            activeScreen: activeScreen,
            modes: full ? modes : [],
            terminalForeground: full ? terminalForeground : nil,
            terminalBackground: full ? terminalBackground : nil,
            terminalCursorColor: full ? terminalCursorColor : nil,
            scrollbackRows: full ? scrollbackRows : 0,
            scrollbackSpans: full ? scrollbackSpans : []
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

    /// Decode a render-grid frame directly from raw JSON data.
    ///
    /// Equivalent to ``decodeJSONObject(_:)`` for callers that already hold the
    /// serialized payload (for example a push-event payload), avoiding a
    /// round-trip through `JSONSerialization`.
    /// - Parameter data: The JSON-encoded frame.
    /// - Returns: The decoded, validated frame.
    /// - Throws: A decoding or validation error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileTerminalRenderGridFrame {
        try JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: data)
    }

    /// Alias for ``vtPatchBytes()``; the byte stream both replaces a full
    /// screen and patches a delta depending on ``full``.
    ///
    /// Forwards to ``MobileTerminalRenderGridReplay/replacementBytes()``; the
    /// VT synthesizer lives there so this DTO stays a pure value.
    public func vtReplacementBytes() -> Data {
        MobileTerminalRenderGridReplay(self).replacementBytes()
    }

    /// Synthesize a VT byte stream that reproduces this frame when fed to a
    /// terminal emulator.
    ///
    /// A **full** frame is a faithful cold-attach snapshot: it resets the
    /// terminal, restores dynamic default colors, repaints scrollback and the
    /// visible viewport as a natural scrolling flow, restores the active screen
    /// (`?1049h` for the alternate screen), reapplies non-default DEC/ANSI
    /// modes, and finally restores the cursor. A **delta** frame clears and
    /// repaints only the changed viewport rows.
    ///
    /// Forwards to ``MobileTerminalRenderGridReplay/patchBytes()``; the VT
    /// synthesizer lives there so this DTO stays a pure value.
    public func vtPatchBytes() -> Data {
        MobileTerminalRenderGridReplay(self).patchBytes()
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
        case activeScreen = "active_screen"
        case modes
        case terminalForeground = "terminal_foreground"
        case terminalBackground = "terminal_background"
        case terminalCursorColor = "terminal_cursor_color"
        case scrollbackRows = "scrollback_rows"
        case scrollbackSpans = "scrollback_spans"
        case gridHash = "grid_hash"
    }

    /// Which terminal screen a full snapshot represents.
    public enum Screen: String, Codable, Equatable, Sendable {
        /// The normal screen, which owns the scrollback history.
        case primary
        /// The alternate screen used by full-screen TUIs (entered with `?1049h`).
        case alternate
    }

    /// One DEC private or ANSI mode to restore on a full snapshot.
    public struct ModeSetting: Codable, Equatable, Sendable {
        /// The numeric mode code (e.g. `2004` for bracketed paste, `1` for
        /// application cursor keys).
        public var code: Int
        /// `true` for an ANSI mode (`CSI {code} h/l`), `false` for a DEC private
        /// mode (`CSI ? {code} h/l`).
        public var ansi: Bool
        /// Whether the mode is currently set.
        public var on: Bool

        public init(code: Int, ansi: Bool = false, on: Bool) {
            self.code = code
            self.ansi = ansi
            self.on = on
        }

        enum CodingKeys: String, CodingKey {
            case code
            case ansi
            case on
        }
    }

    public struct Cursor: Codable, Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var visible: Bool
        public var style: Style
        public var blinking: Bool

        public init(
            row: Int,
            column: Int,
            visible: Bool = true,
            style: Style = .block,
            blinking: Bool = false
        ) {
            self.row = row
            self.column = column
            self.visible = visible
            self.style = style
            self.blinking = blinking
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.row = try container.decode(Int.self, forKey: .row)
            self.column = try container.decode(Int.self, forKey: .column)
            self.visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
            self.style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .block
            self.blinking = try container.decodeIfPresent(Bool.self, forKey: .blinking) ?? false
        }

        public enum Style: String, Codable, Equatable, Sendable {
            case block
            case bar
            case underline
            case blockHollow = "block_hollow"
        }
    }

    public struct Style: Codable, Equatable, Sendable {
        public static let `default` = Style(id: 0)

        public var id: Int
        public var foreground: String?
        public var background: String?
        public var bold: Bool
        public var faint: Bool
        public var italic: Bool
        public var underline: Bool
        public var blink: Bool
        public var inverse: Bool
        public var invisible: Bool
        public var strikethrough: Bool
        public var overline: Bool

        public init(
            id: Int,
            foreground: String? = nil,
            background: String? = nil,
            bold: Bool = false,
            faint: Bool = false,
            italic: Bool = false,
            underline: Bool = false,
            blink: Bool = false,
            inverse: Bool = false,
            invisible: Bool = false,
            strikethrough: Bool = false,
            overline: Bool = false
        ) {
            self.id = id
            self.foreground = foreground
            self.background = background
            self.bold = bold
            self.faint = faint
            self.italic = italic
            self.underline = underline
            self.blink = blink
            self.inverse = inverse
            self.invisible = invisible
            self.strikethrough = strikethrough
            self.overline = overline
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(Int.self, forKey: .id)
            self.foreground = try container.decodeIfPresent(String.self, forKey: .foreground)
            self.background = try container.decodeIfPresent(String.self, forKey: .background)
            self.bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
            self.faint = try container.decodeIfPresent(Bool.self, forKey: .faint) ?? false
            self.italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
            self.underline = try container.decodeIfPresent(Bool.self, forKey: .underline) ?? false
            self.blink = try container.decodeIfPresent(Bool.self, forKey: .blink) ?? false
            self.inverse = try container.decodeIfPresent(Bool.self, forKey: .inverse) ?? false
            self.invisible = try container.decodeIfPresent(Bool.self, forKey: .invisible) ?? false
            self.strikethrough = try container.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
            self.overline = try container.decodeIfPresent(Bool.self, forKey: .overline) ?? false
        }
    }

    public struct RowSpan: Codable, Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var styleID: Int
        public var text: String
        public var cellWidth: Int?

        public init(row: Int, column: Int, styleID: Int = 0, text: String, cellWidth: Int? = nil) {
            self.row = row
            self.column = column
            self.styleID = styleID
            self.text = text
            self.cellWidth = cellWidth
        }

        fileprivate var gridCellWidth: Int {
            cellWidth ?? text.count
        }

        enum CodingKeys: String, CodingKey {
            case row
            case column
            case styleID = "style_id"
            case text
            case cellWidth = "cell_width"
        }
    }
}
