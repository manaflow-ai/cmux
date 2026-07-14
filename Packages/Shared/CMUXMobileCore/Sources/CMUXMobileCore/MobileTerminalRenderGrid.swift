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
    /// Monotonic Mac-side capture order for viewport state. Unlike
    /// ``stateSeq``, this advances for viewport-only changes such as scrolling.
    /// Older hosts omit it, in which case clients retain the byte-sequence
    /// compatibility path.
    public var renderRevision: UInt64?
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
    /// tracking, bracketed paste, application cursor keys, autowrap, etc.).
    /// Delta frames keep only mode state needed to restore after replay-time
    /// coordinate normalization.
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
    /// Count of newer history rows after the captured viewport. A client
    /// replays these rows behind the viewport, then positions its local
    /// scrollback by this amount so both older and newer rows are prefetched.
    public var scrollForwardRows: Int
    /// Styled spans for the newer rows after the viewport, indexed
    /// `0..<scrollForwardRows` from nearest to farthest.
    public var scrollForwardSpans: [RowSpan]
    /// Missing suffix of the true primary active screen after the bounded
    /// newer-history window. This is at most one viewport and is appended last
    /// so subsequent PTY bytes continue from the producer's active bottom.
    public var primaryActiveRows: Int
    /// Styled spans for ``primaryActiveRows``, indexed from the first missing
    /// active-screen row through the producer's active bottom.
    public var primaryActiveSpans: [RowSpan]

    public init(
        format: String = Self.currentFormat,
        surfaceID: String,
        stateSeq: UInt64,
        renderRevision: UInt64? = nil,
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
        scrollForwardRows: Int = 0,
        scrollForwardSpans: [RowSpan] = [],
        primaryActiveRows: Int = 0,
        primaryActiveSpans: [RowSpan] = []
    ) throws {
        guard format == Self.currentFormat else {
            throw MobileTerminalRenderGridError.invalidFormat(format)
        }
        guard columns > 0, rows > 0 else {
            throw MobileTerminalRenderGridError.invalidDimensions(columns: columns, rows: rows)
        }
        try cursor?.validate(columns: columns, rows: rows)
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
        let resolvedScrollForwardRows = max(0, scrollForwardRows)
        for span in scrollForwardSpans {
            guard (0..<resolvedScrollForwardRows).contains(span.row) else {
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
        guard (0...rows).contains(primaryActiveRows) else {
            throw MobileTerminalRenderGridError.invalidRow(primaryActiveRows)
        }
        for span in primaryActiveSpans {
            guard (0..<primaryActiveRows).contains(span.row) else {
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
        self.renderRevision = renderRevision
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
        self.scrollForwardRows = full ? resolvedScrollForwardRows : 0
        self.scrollForwardSpans = full ? scrollForwardSpans : []
        self.primaryActiveRows = full && activeScreen == .primary ? primaryActiveRows : 0
        self.primaryActiveSpans = full && activeScreen == .primary ? primaryActiveSpans : []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        let surfaceID = try container.decode(String.self, forKey: .surfaceID)
        let stateSeq = try container.decode(UInt64.self, forKey: .stateSeq)
        let renderRevision = try container.decodeIfPresent(UInt64.self, forKey: .renderRevision)
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
        let scrollForwardRows = try container.decodeIfPresent(Int.self, forKey: .scrollForwardRows) ?? 0
        let scrollForwardSpans = try container.decodeIfPresent([RowSpan].self, forKey: .scrollForwardSpans) ?? []
        let primaryActiveRows = try container.decodeIfPresent(Int.self, forKey: .primaryActiveRows) ?? 0
        let primaryActiveSpans = try container.decodeIfPresent([RowSpan].self, forKey: .primaryActiveSpans) ?? []
        try self.init(
            format: format,
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderRevision: renderRevision,
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
            scrollForwardRows: scrollForwardRows,
            scrollForwardSpans: scrollForwardSpans,
            primaryActiveRows: primaryActiveRows,
            primaryActiveSpans: primaryActiveSpans
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
    /// modes, and finally restores the cursor. A **delta** frame normalizes
    /// coordinate-affecting modes, then clears and repaints only the changed
    /// viewport rows using absolute producer row indexes.
    ///
    /// Forwards to ``MobileTerminalRenderGridReplay/patchBytes()``; the VT
    /// synthesizer lives there so this DTO stays a pure value.
    public func vtPatchBytes() -> Data {
        MobileTerminalRenderGridReplay(self).patchBytes()
    }

    /// Total styled spans retained by this frame across every history window.
    public var totalSpanCount: Int {
        rowSpans.count + scrollbackSpans.count
            + scrollForwardSpans.count + primaryActiveSpans.count
    }

    enum CodingKeys: String, CodingKey {
        case format
        case surfaceID = "surface_id"
        case stateSeq = "state_seq"
        case renderRevision = "render_revision"
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
        case scrollForwardRows = "scrollforward_rows"
        case scrollForwardSpans = "scrollforward_spans"
        case primaryActiveRows = "primary_active_rows"
        case primaryActiveSpans = "primary_active_spans"
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
        static let decOriginModeCode = 6
        static let decAutowrapModeCode = 7
        static let decAlternateScreenCode = 47
        static let decAlternateScreenSaveCursorCode = 1047
        static let decSaveRestoreCursorCode = 1048
        static let decAlternateScreenSaveRestoreCursorCode = 1049

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

        /// Whether this DEC private mode is autowrap (`CSI ? 7 h/l`).
        public var isDECAutowrapMode: Bool { !ansi && code == Self.decAutowrapModeCode }

        /// Whether this DEC private mode is origin mode (`CSI ? 6 h/l`).
        public var isDECOriginMode: Bool { !ansi && code == Self.decOriginModeCode }

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
        /// The cursor's position relative to the captured viewport. Older
        /// render-grid producers omit this field.
        public var location: Location?
        /// Exact cursor row on the live active screen, when supplied.
        public var activeRow: Int?
        public var style: Style
        public var blinking: Bool

        public init(
            row: Int,
            column: Int,
            visible: Bool = true,
            location: Location? = nil,
            activeRow: Int? = nil,
            style: Style = .block,
            blinking: Bool = false
        ) {
            self.row = row
            self.column = column
            self.visible = visible
            self.location = location
            self.activeRow = activeRow
            self.style = style
            self.blinking = blinking
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.row = try container.decode(Int.self, forKey: .row)
            self.column = try container.decode(Int.self, forKey: .column)
            self.visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
            self.location = try container.decodeIfPresent(Location.self, forKey: .location)
            self.activeRow = try container.decodeIfPresent(Int.self, forKey: .activeRow)
            self.style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .block
            self.blinking = try container.decodeIfPresent(Bool.self, forKey: .blinking) ?? false
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

        enum CodingKeys: String, CodingKey {
            case row
            case column
            case styleID = "style_id"
            case text
            case cellWidth = "cell_width"
        }
    }
}
