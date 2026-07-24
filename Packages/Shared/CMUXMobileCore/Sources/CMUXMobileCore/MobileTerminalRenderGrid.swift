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
    /// Stable identifier for one producer lifetime of ``renderRevision``.
    ///
    /// A surface may be recreated with the same public ID after hibernation or
    /// a Mac reconnect. Its revision counter then restarts at one under a new
    /// epoch, so consumers can order the new stream without accepting delayed
    /// frames from the retired producer.
    public var renderEpoch: String
    /// Monotonic producer capture revision for this surface.
    ///
    /// Unlike ``stateSeq``, this advances for every captured grid, including
    /// geometry-only captures that share the same terminal byte sequence.
    public var renderRevision: UInt64
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
    /// Raw default foreground/background colors for OSC 10/11 replay. DEC
    /// reverse-video remains represented separately in ``modes``. Legacy
    /// producers omit configured defaults. The cursor value remains an optional
    /// dynamic OSC 12 override.
    public var terminalForeground: String?
    public var terminalBackground: String?
    public var terminalCursorColor: String?
    /// The Mac terminal's resolved theme when this is a full snapshot.
    ///
    /// Mobile chrome uses this value to match the mirrored surface. Delta
    /// frames omit it because the most recent full snapshot remains
    /// authoritative until another full snapshot replaces it.
    public var terminalTheme: TerminalTheme?
    /// The Mac terminal's raw configuration defaults when this is a full snapshot.
    ///
    /// Unlike ``terminalTheme``, these colors do not include OSC overrides or
    /// DEC reverse-video. A mirror installs them as its Ghostty configuration so
    /// OSC reset commands restore the same defaults as the Mac.
    public var terminalConfigTheme: TerminalTheme?
    /// Monotonic producer order for full-frame theme metadata.
    public var terminalThemeRevision: UInt64?
    /// Count of scrollback lines carried in ``scrollbackSpans`` (rows above the
    /// visible viewport, oldest first). Carried on full primary-screen
    /// snapshots and on screen-anchored burst deltas (``scrolledRows`` larger
    /// than the grid), where they are the history rows that scrolled through
    /// between producer captures; the alternate screen has no scrollback.
    public var scrollbackRows: Int
    /// Styled spans for the scrollback lines, row index `0..<scrollbackRows`
    /// (oldest first). Reuses ``styles`` by `styleID`.
    public var scrollbackSpans: [RowSpan]
    /// Which grid the frame's rows are anchored to. ``Anchor/viewport`` is the
    /// v1 mirror contract: rows follow the producer's live scroll position.
    /// ``Anchor/screen`` anchors rows to the active area so a consumer keeps
    /// its own local viewport and scrollback, independent of the producer's
    /// scroll position.
    public var anchor: Anchor
    /// Rows the producer pushed into scrollback history since the previously
    /// emitted frame (screen-anchored deltas only). The replay scrolls the
    /// consumer's grid by this amount before repainting changed rows, so local
    /// scrollback accumulates exactly like the producer's.
    public var scrolledRows: Int
    /// Total retained history rows above the producer's active area at capture
    /// time. Producers diff consecutive values to compute ``scrolledRows``.
    public var historyRows: UInt64?
    /// ``historyRows`` of the producer's previously emitted frame — the base
    /// this delta was diffed against. A consumer whose last delivered frame
    /// has a different history count missed a frame; its grid and scrollback
    /// alignment can no longer be patched, so it must request a full replay.
    public var deltaBaseHistoryRows: UInt64?
    /// Monotonic identity of the producer's absolute row space. It changes when
    /// retained rows can move to different offsets (scrollback eviction,
    /// reflow, erase), invalidating history-growth arithmetic for that step.
    public var rowSpaceRevision: UInt64?

    public init(
        format: String = Self.currentFormat,
        surfaceID: String,
        stateSeq: UInt64,
        renderEpoch: String = "",
        renderRevision: UInt64 = 0,
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
        terminalTheme: TerminalTheme? = nil,
        terminalConfigTheme: TerminalTheme? = nil,
        terminalThemeRevision: UInt64? = nil,
        scrollbackRows: Int = 0,
        scrollbackSpans: [RowSpan] = [],
        anchor: Anchor = .viewport,
        scrolledRows: Int = 0,
        historyRows: UInt64? = nil,
        rowSpaceRevision: UInt64? = nil,
        deltaBaseHistoryRows: UInt64? = nil
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
        self.renderEpoch = renderEpoch
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
        self.terminalTheme = full ? terminalTheme?.validatedOrDefault() : nil
        self.terminalConfigTheme = full ? terminalConfigTheme?.validatedOrDefault() : nil
        self.terminalThemeRevision = full ? terminalThemeRevision : nil
        // Full frames never scroll (the replay resets the terminal), and only
        // screen-anchored deltas may scroll. A burst delta (more rows scrolled
        // than the producer captured between frames) additionally carries the
        // missed history rows as scrollback spans.
        let resolvedScrolledRows = (full || anchor != .screen) ? 0 : max(0, scrolledRows)
        self.scrolledRows = resolvedScrolledRows
        let carriesScrollback = full || resolvedScrolledRows > 0
        self.scrollbackRows = carriesScrollback ? resolvedScrollbackRows : 0
        self.scrollbackSpans = carriesScrollback ? scrollbackSpans : []
        self.anchor = anchor
        self.historyRows = historyRows
        self.rowSpaceRevision = rowSpaceRevision
        self.deltaBaseHistoryRows = full ? nil : deltaBaseHistoryRows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let format = try container.decode(String.self, forKey: .format)
        let surfaceID = try container.decode(String.self, forKey: .surfaceID)
        let stateSeq = try container.decode(UInt64.self, forKey: .stateSeq)
        let renderEpoch = try container.decodeIfPresent(String.self, forKey: .renderEpoch) ?? ""
        let renderRevision = try container.decodeIfPresent(UInt64.self, forKey: .renderRevision) ?? 0
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
        let terminalTheme = try container.decodeIfPresent(TerminalTheme.self, forKey: .terminalTheme)
        let terminalConfigTheme = try container.decodeIfPresent(TerminalTheme.self, forKey: .terminalConfigTheme)
        let terminalThemeRevision = try container.decodeIfPresent(UInt64.self, forKey: .terminalThemeRevision)
        let scrollbackRows = try container.decodeIfPresent(Int.self, forKey: .scrollbackRows) ?? 0
        let scrollbackSpans = try container.decodeIfPresent([RowSpan].self, forKey: .scrollbackSpans) ?? []
        let anchor = try container.decodeIfPresent(Anchor.self, forKey: .anchor) ?? .viewport
        let scrolledRows = try container.decodeIfPresent(Int.self, forKey: .scrolledRows) ?? 0
        let historyRows = try container.decodeIfPresent(UInt64.self, forKey: .historyRows)
        let rowSpaceRevision = try container.decodeIfPresent(UInt64.self, forKey: .rowSpaceRevision)
        let deltaBaseHistoryRows = try container.decodeIfPresent(UInt64.self, forKey: .deltaBaseHistoryRows)
        try self.init(
            format: format,
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderEpoch: renderEpoch,
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
            terminalTheme: terminalTheme,
            terminalConfigTheme: terminalConfigTheme,
            terminalThemeRevision: terminalThemeRevision,
            scrollbackRows: scrollbackRows,
            scrollbackSpans: scrollbackSpans,
            anchor: anchor,
            scrolledRows: scrolledRows,
            historyRows: historyRows,
            rowSpaceRevision: rowSpaceRevision,
            deltaBaseHistoryRows: deltaBaseHistoryRows
        )
    }

    public static func fromPlainRows(
        surfaceID: String,
        stateSeq: UInt64,
        renderEpoch: String = "",
        renderRevision: UInt64 = 0,
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
            let clipped = trimmed.clippedToRenderGridColumns(columns)
            guard !clipped.isEmpty else { return nil }
            return RowSpan(
                row: row,
                column: 0,
                styleID: 0,
                text: clipped
            )
        }
        return try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderEpoch: renderEpoch,
            renderRevision: renderRevision,
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
        let foregroundSource = style.foregroundSource?.rawValue ?? "legacy"
        let backgroundSource = style.backgroundSource?.rawValue ?? "legacy"
        return "\(style.foreground ?? "-"):\(foregroundSource):\(style.foregroundPaletteIndex ?? -1)/" +
            "\(style.background ?? "-"):\(backgroundSource):\(style.backgroundPaletteIndex ?? -1)/\(flags)"
    }

    public func filteredRows(
        _ includedRows: Set<Int>,
        full: Bool,
        scrolledRows: Int = 0,
        carryScrollbackSpans: Bool = false,
        deltaBaseHistoryRows: UInt64? = nil
    ) throws -> MobileTerminalRenderGridFrame {
        // A screen-anchored burst delta keeps the frame's scrollback spans:
        // they are the history rows that scrolled through between producer
        // captures, replayed ahead of the visible-grid repaint.
        let carriesScrollback = full || (carryScrollbackSpans && scrolledRows > 0)
        return try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderEpoch: renderEpoch,
            renderRevision: renderRevision,
            columns: columns,
            rows: rows,
            cursor: cursor,
            full: full,
            clearedRows: full ? [] : Array(includedRows.sorted()),
            styles: styles,
            rowSpans: rowSpans.filter { includedRows.contains($0.row) },
            // Deltas only carry autowrap; DECOM needs a full snapshot because
            // restoring it homes the cursor and requires scroll-region state.
            activeScreen: activeScreen,
            modes: full ? modes : modes.filter(\.isDECAutowrapMode),
            terminalForeground: full ? terminalForeground : nil,
            terminalBackground: full ? terminalBackground : nil,
            terminalCursorColor: full ? terminalCursorColor : nil,
            terminalTheme: full ? terminalTheme : nil,
            terminalConfigTheme: full ? terminalConfigTheme : nil,
            terminalThemeRevision: full ? terminalThemeRevision : nil,
            scrollbackRows: carriesScrollback ? scrollbackRows : 0,
            scrollbackSpans: carriesScrollback ? scrollbackSpans : [],
            anchor: anchor,
            scrolledRows: full ? 0 : scrolledRows,
            historyRows: historyRows,
            rowSpaceRevision: rowSpaceRevision,
            deltaBaseHistoryRows: deltaBaseHistoryRows
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
    /// modes, and finally restores the cursor. A **delta** frame normalizes
    /// coordinate-affecting modes, then clears and repaints only the changed
    /// viewport rows using absolute producer row indexes.
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

    /// Which terminal screen a full snapshot represents.
    public enum Screen: String, Codable, Equatable, Sendable {
        /// The normal screen, which owns the scrollback history.
        case primary
        /// The alternate screen used by full-screen TUIs (entered with `?1049h`).
        case alternate
    }

    /// Which producer grid the frame's row indexes address.
    public enum Anchor: String, Codable, Equatable, Sendable {
        /// Rows follow the producer's live viewport (v1 mirror semantics).
        case viewport
        /// Rows address the active area regardless of the producer's scroll
        /// position; the consumer owns its local viewport and scrollback.
        case screen
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
