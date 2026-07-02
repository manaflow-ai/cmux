import Foundation

/// Synthesizes a VT byte stream that reproduces a ``MobileTerminalRenderGridFrame``
/// when fed to a terminal emulator.
///
/// The replay is a pure, stateless transform: it reads the frame's value
/// properties and emits the escape-sequence bytes that paint it. Splitting the
/// synthesizer out of ``MobileTerminalRenderGridFrame`` keeps the wire DTO a
/// pure value with no rendering policy, while ``MobileTerminalRenderGridFrame``
/// retains thin ``MobileTerminalRenderGridFrame/vtPatchBytes()`` /
/// ``MobileTerminalRenderGridFrame/vtReplacementBytes()`` accessors that
/// forward here for call-site compatibility.
public struct MobileTerminalRenderGridReplay: Sendable {
    /// The frame this replay renders into VT bytes.
    public let frame: MobileTerminalRenderGridFrame

    /// Creates a replay over `frame`.
    ///
    /// - Parameter frame: The render-grid frame to synthesize bytes for.
    public init(_ frame: MobileTerminalRenderGridFrame) {
        self.frame = frame
    }

    /// Synthesize a VT byte stream that reproduces ``frame`` when fed to a
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
    /// - Returns: The synthesized escape-sequence bytes.
    public func patchBytes() -> Data {
        frame.full ? fullSnapshotBytes() : deltaPatchBytes()
    }

    /// Alias for ``patchBytes()``; the byte stream both replaces a full screen
    /// and patches a delta depending on ``MobileTerminalRenderGridFrame/full``.
    ///
    /// - Returns: The synthesized escape-sequence bytes.
    public func replacementBytes() -> Data {
        patchBytes()
    }

    private func deltaPatchBytes() -> Data {
        var bytes = Data()
        let stylesByID = styleMapByID(frame.styles)
        let defaultStyle = stylesByID[0] ?? .default
        let modeState = deltaReplayModeState()
        if modeState != nil {
            bytes.append(deltaReplayModeNormalizationBytes())
        }
        let rowsToClear = Set(frame.clearedRows).union(frame.rowSpans.map(\.row)).sorted()
        for row in rowsToClear {
            bytes.append(sgrBytes(for: defaultStyle))
            bytes.append(Data("\u{1B}[\(row + 1);1H\u{1B}[2K".utf8))
        }
        var activeStyleID: Int?
        for span in frame.rowSpans {
            guard !span.text.isEmpty else { continue }
            let style = activeStyleID != span.styleID ? stylesByID[span.styleID] : nil
            appendSpanReplay(span, row: span.row, style: style, to: &bytes)
            if activeStyleID != span.styleID,
               style != nil {
                activeStyleID = span.styleID
            }
        }
        bytes.append(sgrBytes(for: defaultStyle))
        if let modeState { bytes.append(modeBytes(modeState.autowrap)) }
        // A delta never hides the cursor while painting, so (unlike a full
        // snapshot) it leaves a nil cursor untouched instead of forcing it
        // visible.
        if let cursor = frame.cursor {
            bytes.append(cursorStyleBytes(for: cursor))
            if cursor.visible {
                bytes.append(Data("\u{1B}[?25h\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H".utf8))
            } else {
                bytes.append(Data("\u{1B}[?25l".utf8))
            }
        }
        if let modeState { bytes.append(modeBytes(modeState.origin)) }
        return bytes
    }

    private func fullSnapshotBytes() -> Data {
        var bytes = Data()
        let stylesByID = styleMapByID(frame.styles)
        let defaultStyle = stylesByID[0] ?? .default

        // Reset to a known state, then apply everything inside a synchronized
        // update so the client never shows a partially-restored screen.
        bytes.append(Data("\u{1B}c".utf8))
        bytes.append(Data("\u{1B}[?2026h".utf8))

        // Dynamic default colors (OSC 10/11/12). Cells already carry explicit
        // RGB, so these mainly fix the cursor color and color queries.
        if let osc = oscColorBytes(10, frame.terminalForeground) { bytes.append(osc) }
        if let osc = oscColorBytes(11, frame.terminalBackground) { bytes.append(osc) }
        if let osc = oscColorBytes(12, frame.terminalCursorColor) { bytes.append(osc) }

        // Paint with autowrap and the cursor off so a full-width row plus an
        // explicit newline cannot wrap into a phantom blank line, and so the
        // restore does not flicker the cursor across the grid.
        bytes.append(Data("\u{1B}[?7l\u{1B}[?25l".utf8))
        bytes.append(sgrBytes(for: defaultStyle))

        if frame.activeScreen == .alternate {
            // Scrollback belongs to the primary screen; flow it there first so
            // it is preserved behind the alternate screen, then enter the
            // alternate screen and paint the TUI viewport.
            appendFlowLines(
                &bytes,
                spans: frame.scrollbackSpans,
                lineCount: frame.scrollbackRows,
                stylesByID: stylesByID,
                defaultStyle: defaultStyle,
                terminateLast: true
            )
            bytes.append(Data("\u{1B}[?1049h".utf8))
            bytes.append(sgrBytes(for: defaultStyle))
            appendFlowLines(
                &bytes,
                spans: frame.rowSpans,
                lineCount: frame.rows,
                stylesByID: stylesByID,
                defaultStyle: defaultStyle,
                terminateLast: false
            )
        } else {
            // Primary: scrollback then the viewport as one continuous flow so
            // the scrollback naturally lands in the client's history.
            let offsetViewportSpans = frame.rowSpans.map { span in
                MobileTerminalRenderGridFrame.RowSpan(
                    row: span.row + frame.scrollbackRows,
                    column: span.column,
                    styleID: span.styleID,
                    text: span.text,
                    cellWidth: span.cellWidth
                )
            }
            appendFlowLines(
                &bytes,
                spans: frame.scrollbackSpans + offsetViewportSpans,
                lineCount: frame.scrollbackRows + frame.rows,
                stylesByID: stylesByID,
                defaultStyle: defaultStyle,
                terminateLast: false
            )
        }

        // Reapply modes last so mouse/paste/app-key modes are live. Screen
        // switches are handled by the replay wrapper to avoid duplicated toggles.
        for mode in frame.modes where !isScreenSwitchPrivateMode(mode) {
            bytes.append(modeBytes(mode))
        }

        appendCursorRestore(&bytes)
        bytes.append(Data("\u{1B}[?2026l".utf8))
        return bytes
    }

    private func deltaReplayModeNormalizationBytes() -> Data {
        // Disable origin mode so CUP row indexes target absolute viewport rows,
        // and disable autowrap while painting so full-width spans cannot scroll
        // a preserved scroll region.
        Data((
            "\u{1B}[?\(MobileTerminalRenderGridFrame.ModeSetting.decOriginModeCode)l" +
            "\u{1B}[?\(MobileTerminalRenderGridFrame.ModeSetting.decAutowrapModeCode)l"
        ).utf8)
    }

    private func deltaReplayModeState() -> (origin: MobileTerminalRenderGridFrame.ModeSetting, autowrap: MobileTerminalRenderGridFrame.ModeSetting)? {
        guard let origin = frame.modes.first(where: \.isDECOriginMode), let autowrap = frame.modes.first(where: \.isDECAutowrapMode) else {
            return nil
        }
        return (origin, autowrap)
    }

    /// Append `lineCount` lines (rows `0..<lineCount` of `spans`) as a natural
    /// scrolling flow: each line resets to the default style, positions its
    /// spans with `CHA`, and is separated from the next by CRLF.
    private func appendFlowLines(
        _ bytes: inout Data,
        spans: [MobileTerminalRenderGridFrame.RowSpan],
        lineCount: Int,
        stylesByID: [Int: MobileTerminalRenderGridFrame.Style],
        defaultStyle: MobileTerminalRenderGridFrame.Style,
        terminateLast: Bool
    ) {
        guard lineCount > 0 else { return }
        var spansByRow: [Int: [MobileTerminalRenderGridFrame.RowSpan]] = [:]
        for span in spans {
            spansByRow[span.row, default: []].append(span)
        }
        for line in 0..<lineCount {
            if line > 0 {
                bytes.append(Data("\r\n".utf8))
            }
            bytes.append(sgrBytes(for: defaultStyle))
            var activeStyleID = 0
            for span in (spansByRow[line] ?? []).sorted(by: { $0.column < $1.column }) {
                guard !span.text.isEmpty else { continue }
                let style = activeStyleID != span.styleID ? stylesByID[span.styleID] : nil
                appendSpanReplay(span, row: nil, style: style, to: &bytes)
                if activeStyleID != span.styleID,
                   style != nil {
                    activeStyleID = span.styleID
                }
            }
        }
        if terminateLast {
            bytes.append(Data("\r\n".utf8))
        }
    }

    private func appendSpanReplay(
        _ span: MobileTerminalRenderGridFrame.RowSpan,
        row: Int?,
        style: MobileTerminalRenderGridFrame.Style?,
        to bytes: inout Data
    ) {
        guard shouldPinColumns(for: span) else {
            appendCursor(row: row, column: span.column, to: &bytes)
            if let style {
                bytes.append(sgrBytes(for: style))
            }
            appendVTPrintable(span.text, to: &bytes)
            return
        }

        guard let widths = sourceCellWidths(for: span.text, targetWidth: span.gridCellWidth) else {
            appendCursor(row: row, column: span.column, to: &bytes)
            if let style {
                bytes.append(sgrBytes(for: style))
            }
            appendVTPrintable(span.text, to: &bytes)
            return
        }

        var column = span.column
        var needsStyle = true
        for (character, width) in zip(span.text, widths) {
            appendCursor(row: row, column: column, to: &bytes)
            if needsStyle {
                if let style {
                    bytes.append(sgrBytes(for: style))
                }
                needsStyle = false
            }
            appendVTPrintable(character, to: &bytes)
            column += width
        }
    }

    private func shouldPinColumns(
        for span: MobileTerminalRenderGridFrame.RowSpan
    ) -> Bool {
        guard span.hasWidthSensitiveScalars else { return false }
        let characterCount = span.text.count
        guard characterCount > 1 else { return false }
        return true
    }

    private func sourceCellWidths(
        for text: String,
        targetWidth: Int
    ) -> [Int]? {
        guard !text.isEmpty, targetWidth > 0 else { return nil }
        var widths: [Int] = []
        var expandable: [Bool] = []
        var hasUntrustedExpansionCandidate = false
        widths.reserveCapacity(text.count)
        expandable.reserveCapacity(text.count)
        for character in text {
            let width = character.renderGridEstimatedCellWidth
            let canExpand = character.canExpandForAmbiguousRenderGridWidth
            widths.append(width)
            expandable.append(canExpand)
            if width == 1,
               !canExpand,
               character.unicodeScalars.contains(where: {
                   $0.value > 0x7F
                       && !$0.isRenderGridZeroWidthScalar
               }) {
                hasUntrustedExpansionCandidate = true
            }
        }
        let total = widths.reduce(0, +)
        if total < targetWidth {
            guard !hasUntrustedExpansionCandidate else {
                return nil
            }
            var remaining = targetWidth - total
            for index in widths.indices where remaining > 0 && widths[index] < 2 {
                guard expandable[index] else {
                    continue
                }
                widths[index] += 1
                remaining -= 1
            }
            guard remaining == 0 else {
                return nil
            }
        } else if total > targetWidth {
            var excess = total - targetWidth
            for index in widths.indices.reversed() where excess > 0 && widths[index] > 1 {
                widths[index] -= 1
                excess -= 1
            }
            guard excess == 0 else {
                return nil
            }
        }
        return widths
    }

    private func appendCursor(row: Int?, column: Int, to bytes: inout Data) {
        if let row {
            bytes.append(0x1B)
            bytes.append(0x5B)
            appendDecimal(row + 1, to: &bytes)
            bytes.append(0x3B)
            appendDecimal(column + 1, to: &bytes)
            bytes.append(0x48)
        } else {
            bytes.append(0x1B)
            bytes.append(0x5B)
            appendDecimal(column + 1, to: &bytes)
            bytes.append(0x47)
        }
    }

    private func appendDecimal(_ value: Int, to bytes: inout Data) {
        let value = max(0, value)
        if value >= 10000 {
            var divisor = 1
            while divisor <= value / 10 {
                divisor *= 10
            }
            var remaining = value
            while divisor > 0 {
                bytes.append(UInt8(48 + remaining / divisor))
                remaining %= divisor
                divisor /= 10
            }
            return
        }

        if value >= 1000 {
            bytes.append(UInt8(48 + value / 1000))
            bytes.append(UInt8(48 + value / 100 % 10))
            bytes.append(UInt8(48 + value / 10 % 10))
            bytes.append(UInt8(48 + value % 10))
        } else if value >= 100 {
            bytes.append(UInt8(48 + value / 100))
            bytes.append(UInt8(48 + value / 10 % 10))
            bytes.append(UInt8(48 + value % 10))
        } else if value >= 10 {
            bytes.append(UInt8(48 + value / 10))
            bytes.append(UInt8(48 + value % 10))
        } else {
            bytes.append(UInt8(48 + value))
        }
    }

    private func appendCursorRestore(_ bytes: inout Data) {
        let defaultStyle = styleMapByID(frame.styles)[0] ?? .default
        bytes.append(sgrBytes(for: defaultStyle))
        guard let cursor = frame.cursor else {
            bytes.append(Data("\u{1B}[?25h".utf8))
            return
        }
        bytes.append(cursorStyleBytes(for: cursor))
        if cursor.visible {
            bytes.append(Data("\u{1B}[?25h\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H".utf8))
        } else {
            bytes.append(Data("\u{1B}[?25l\u{1B}[\(cursor.row + 1);\(cursor.column + 1)H".utf8))
        }
    }

    private func styleMapByID(
        _ styles: [MobileTerminalRenderGridFrame.Style]
    ) -> [Int: MobileTerminalRenderGridFrame.Style] {
        var map: [Int: MobileTerminalRenderGridFrame.Style] = [:]
        for style in styles {
            map[style.id] = style
        }
        return map
    }

    private func modeBytes(_ mode: MobileTerminalRenderGridFrame.ModeSetting) -> Data {
        let prefix = mode.ansi ? "\u{1B}[" : "\u{1B}[?"
        return Data("\(prefix)\(mode.code)\(mode.on ? "h" : "l")".utf8)
    }

    private func isScreenSwitchPrivateMode(_ mode: MobileTerminalRenderGridFrame.ModeSetting) -> Bool {
        guard !mode.ansi else { return false }
        // Screen switches are represented by `activeScreen`; replay emits the
        // owning switch once so mode-state restore cannot duplicate it.
        switch mode.code {
        case MobileTerminalRenderGridFrame.ModeSetting.decAlternateScreenCode,
             MobileTerminalRenderGridFrame.ModeSetting.decAlternateScreenSaveCursorCode,
             MobileTerminalRenderGridFrame.ModeSetting.decSaveRestoreCursorCode,
             MobileTerminalRenderGridFrame.ModeSetting.decAlternateScreenSaveRestoreCursorCode:
            return true
        default:
            return false
        }
    }

    private func oscColorBytes(_ ps: Int, _ hex: String?) -> Data? {
        guard let rgb = rgbComponents(hex) else { return nil }
        let spec = String(
            format: "rgb:%02x/%02x/%02x",
            rgb.red,
            rgb.green,
            rgb.blue
        )
        return Data("\u{1B}]\(ps);\(spec)\u{1B}\\".utf8)
    }

    private func appendVTPrintable(_ text: String, to bytes: inout Data) {
        for scalar in text.unicodeScalars {
            appendVTPrintable(scalar, to: &bytes)
        }
    }

    private func appendVTPrintable(_ character: Character, to bytes: inout Data) {
        for scalar in character.unicodeScalars {
            appendVTPrintable(scalar, to: &bytes)
        }
    }

    private func appendVTPrintable(_ scalar: UnicodeScalar, to bytes: inout Data) {
        switch scalar.value {
        case 0x20...0x7E,
             0xA0...0x10FFFF:
            appendUTF8(scalar, to: &bytes)
        default:
            bytes.append(0x20)
        }
    }

    private func appendUTF8(_ scalar: UnicodeScalar, to bytes: inout Data) {
        let value = scalar.value
        if value <= 0x7F {
            bytes.append(UInt8(value))
        } else if value <= 0x7FF {
            bytes.append(UInt8(0xC0 | (value >> 6)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        } else if value <= 0xFFFF {
            bytes.append(UInt8(0xE0 | (value >> 12)))
            bytes.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        } else {
            bytes.append(UInt8(0xF0 | (value >> 18)))
            bytes.append(UInt8(0x80 | ((value >> 12) & 0x3F)))
            bytes.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            bytes.append(UInt8(0x80 | (value & 0x3F)))
        }
    }

    private func sgrBytes(for style: MobileTerminalRenderGridFrame.Style) -> Data {
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

    private func cursorStyleBytes(for cursor: MobileTerminalRenderGridFrame.Cursor) -> Data {
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

    private func rgbComponents(_ value: String?) -> (red: Int, green: Int, blue: Int)? {
        guard var value else { return nil }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let raw = Int(value, radix: 16) else { return nil }
        return ((raw >> 16) & 0xFF, (raw >> 8) & 0xFF, raw & 0xFF)
    }
}
