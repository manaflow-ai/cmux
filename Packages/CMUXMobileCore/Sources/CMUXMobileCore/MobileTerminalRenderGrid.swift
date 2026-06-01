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
        scrollbackSpans: [RowSpan] = []
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
            scrollbackSpans: scrollbackSpans
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

    /// Alias for ``vtPatchBytes()``; the byte stream both replaces a full
    /// screen and patches a delta depending on ``full``.
    public func vtReplacementBytes() -> Data {
        vtPatchBytes()
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
    public func vtPatchBytes() -> Data {
        full ? fullSnapshotBytes() : deltaPatchBytes()
    }

    /// DEC private mode codes that switch screens or save the cursor. The
    /// active screen is restored explicitly via ``activeScreen``, so these are
    /// never replayed from ``modes`` (replaying them would double-switch).
    private static let screenSwitchModeCodes: Set<Int> = [47, 1047, 1048, 1049]

    private func deltaPatchBytes() -> Data {
        var bytes = Data()
        let stylesByID = Self.stylesByID(styles)
        let defaultStyle = stylesByID[0] ?? .default
        let rowsToClear = Set(clearedRows).union(rowSpans.map(\.row)).sorted()
        for row in rowsToClear {
            bytes.append(Self.sgrBytes(for: defaultStyle))
            bytes.append(Data("\u{1B}[\(row + 1);1H\u{1B}[2K".utf8))
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
        bytes.append(Self.sgrBytes(for: defaultStyle))
        // A delta never hides the cursor while painting, so (unlike a full
        // snapshot) it leaves a nil cursor untouched instead of forcing it
        // visible.
        if let cursor {
            bytes.append(Self.cursorStyleBytes(for: cursor))
            if cursor.visible {
                bytes.append(Data("\u{1B}[?25h\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H".utf8))
            } else {
                bytes.append(Data("\u{1B}[?25l".utf8))
            }
        }
        return bytes
    }

    private func fullSnapshotBytes() -> Data {
        var bytes = Data()
        let stylesByID = Self.stylesByID(styles)
        let defaultStyle = stylesByID[0] ?? .default

        // Reset to a known state, then apply everything inside a synchronized
        // update so the client never shows a partially-restored screen.
        bytes.append(Data("\u{1B}c".utf8))
        bytes.append(Data("\u{1B}[?2026h".utf8))

        // Dynamic default colors (OSC 10/11/12). Cells already carry explicit
        // RGB, so these mainly fix the cursor color and color queries.
        if let osc = Self.oscColorBytes(10, terminalForeground) { bytes.append(osc) }
        if let osc = Self.oscColorBytes(11, terminalBackground) { bytes.append(osc) }
        if let osc = Self.oscColorBytes(12, terminalCursorColor) { bytes.append(osc) }

        // Paint with autowrap and the cursor off so a full-width row plus an
        // explicit newline cannot wrap into a phantom blank line, and so the
        // restore does not flicker the cursor across the grid.
        bytes.append(Data("\u{1B}[?7l\u{1B}[?25l".utf8))
        bytes.append(Self.sgrBytes(for: defaultStyle))

        if activeScreen == .alternate {
            // Scrollback belongs to the primary screen; flow it there first so
            // it is preserved behind the alternate screen, then enter the
            // alternate screen and paint the TUI viewport.
            appendFlowLines(
                &bytes,
                spans: scrollbackSpans,
                lineCount: scrollbackRows,
                stylesByID: stylesByID,
                defaultStyle: defaultStyle,
                terminateLast: true
            )
            bytes.append(Data("\u{1B}[?1049h".utf8))
            bytes.append(Self.sgrBytes(for: defaultStyle))
            appendFlowLines(
                &bytes,
                spans: rowSpans,
                lineCount: rows,
                stylesByID: stylesByID,
                defaultStyle: defaultStyle,
                terminateLast: false
            )
        } else {
            // Primary: scrollback then the viewport as one continuous flow so
            // the scrollback naturally lands in the client's history.
            let offsetViewportSpans = rowSpans.map { span in
                RowSpan(
                    row: span.row + scrollbackRows,
                    column: span.column,
                    styleID: span.styleID,
                    text: span.text,
                    cellWidth: span.cellWidth
                )
            }
            appendFlowLines(
                &bytes,
                spans: scrollbackSpans + offsetViewportSpans,
                lineCount: scrollbackRows + rows,
                stylesByID: stylesByID,
                defaultStyle: defaultStyle,
                terminateLast: false
            )
        }

        // Reapply modes last so autowrap returns to its captured value
        // (undoing the temporary `?7l`) and mouse/paste/app-key modes are live.
        for mode in modes where !Self.screenSwitchModeCodes.contains(mode.code) {
            bytes.append(Self.modeBytes(mode))
        }

        appendCursorRestore(&bytes)
        bytes.append(Data("\u{1B}[?2026l".utf8))
        return bytes
    }

    /// Append `lineCount` lines (rows `0..<lineCount` of `spans`) as a natural
    /// scrolling flow: each line resets to the default style, positions its
    /// spans with `CHA`, and is separated from the next by CRLF.
    private func appendFlowLines(
        _ bytes: inout Data,
        spans: [RowSpan],
        lineCount: Int,
        stylesByID: [Int: Style],
        defaultStyle: Style,
        terminateLast: Bool
    ) {
        guard lineCount > 0 else { return }
        var spansByRow: [Int: [RowSpan]] = [:]
        for span in spans {
            spansByRow[span.row, default: []].append(span)
        }
        for line in 0..<lineCount {
            if line > 0 {
                bytes.append(Data("\r\n".utf8))
            }
            bytes.append(Self.sgrBytes(for: defaultStyle))
            var activeStyleID = 0
            for span in (spansByRow[line] ?? []).sorted(by: { $0.column < $1.column }) {
                bytes.append(Data("\u{1B}[\(span.column + 1)G".utf8))
                if activeStyleID != span.styleID,
                   let style = stylesByID[span.styleID] {
                    bytes.append(Self.sgrBytes(for: style))
                    activeStyleID = span.styleID
                }
                bytes.append(Self.vtPrintableBytes(span.text))
            }
        }
        if terminateLast {
            bytes.append(Data("\r\n".utf8))
        }
    }

    private func appendCursorRestore(_ bytes: inout Data) {
        let defaultStyle = Self.stylesByID(styles)[0] ?? .default
        bytes.append(Self.sgrBytes(for: defaultStyle))
        guard let cursor else {
            bytes.append(Data("\u{1B}[?25h".utf8))
            return
        }
        bytes.append(Self.cursorStyleBytes(for: cursor))
        if cursor.visible {
            bytes.append(Data("\u{1B}[?25h\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H".utf8))
        } else {
            bytes.append(Data("\u{1B}[?25l\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H".utf8))
        }
    }

    private static func stylesByID(_ styles: [Style]) -> [Int: Style] {
        var map: [Int: Style] = [:]
        for style in styles {
            map[style.id] = style
        }
        return map
    }

    private static func modeBytes(_ mode: ModeSetting) -> Data {
        let prefix = mode.ansi ? "\u{1B}[" : "\u{1B}[?"
        return Data("\(prefix)\(mode.code)\(mode.on ? "h" : "l")".utf8)
    }

    private static func oscColorBytes(_ ps: Int, _ hex: String?) -> Data? {
        guard let rgb = rgbComponents(hex) else { return nil }
        let spec = String(
            format: "rgb:%02x/%02x/%02x",
            rgb.red,
            rgb.green,
            rgb.blue
        )
        return Data("\u{1B}]\(ps);\(spec)\u{1B}\\".utf8)
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
        if style.faint { codes.append("2") }
        if style.italic { codes.append("3") }
        if style.underline { codes.append("4") }
        if style.blink { codes.append("5") }
        if style.inverse { codes.append("7") }
        if style.invisible { codes.append("8") }
        if style.strikethrough { codes.append("9") }
        if style.overline { codes.append("53") }
        if let foreground = rgbComponents(style.foreground) {
            codes.append("38;2;\(foreground.red);\(foreground.green);\(foreground.blue)")
        }
        if let background = rgbComponents(style.background) {
            codes.append("48;2;\(background.red);\(background.green);\(background.blue)")
        }
        return Data("\u{1B}[\(codes.joined(separator: ";"))m".utf8)
    }

    private static func cursorStyleBytes(for cursor: Cursor) -> Data {
        let parameter: Int
        switch cursor.style {
        case .block, .blockHollow:
            parameter = cursor.blinking ? 1 : 2
        case .underline:
            parameter = cursor.blinking ? 3 : 4
        case .bar:
            parameter = cursor.blinking ? 5 : 6
        }
        return Data("\u{1B}[\(parameter) q".utf8)
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
        case activeScreen = "active_screen"
        case modes
        case terminalForeground = "terminal_foreground"
        case terminalBackground = "terminal_background"
        case terminalCursorColor = "terminal_cursor_color"
        case scrollbackRows = "scrollback_rows"
        case scrollbackSpans = "scrollback_spans"
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
