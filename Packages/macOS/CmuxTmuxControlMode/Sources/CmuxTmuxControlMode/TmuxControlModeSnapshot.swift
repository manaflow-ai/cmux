import Foundation

/// Converts a tmux `capture-pane` result plus pane state into a replacement
/// stream for a local terminal emulator.
///
/// `capture-pane` returns rows, not a complete VT state transition. A mirror
/// must replace its old grid and restore the state that live `%output` bytes do
/// not repeat. Keeping this conversion in the protocol package makes attach,
/// flow-control recovery, and tests use the same transaction.
enum TmuxControlModeSnapshot {
    /// Reset the emulator and erase the old scrollback before a replacement
    /// capture. This is the same reset used by cmux-tui's pipe relay.
    static let replacementReset = Data(TerminalSessionSnapshot.replacementPrefix)

    /// Paint a captured pane as a replacement frame and restore its terminal
    /// state. The last captured row has no trailing newline so the cursor does
    /// not move below the prompt before the state sequence places it exactly.
    static func render(
        lines: [String],
        alternateScreen: Bool,
        stateLine: String?
    ) -> [UInt8] {
        var data = Data()
        data.append(replacementReset)
        // A surface can be reused after a previous attach. Explicitly leave
        // the old alternate screen before selecting the authoritative one.
        data.append(Data("\u{1b}[?1049l".utf8))
        if alternateScreen {
            data.append(Data("\u{1b}[?1049h".utf8))
        }
        data.append(Data("\u{1b}[H\u{1b}[2J".utf8))
        data.append(Data(lines.joined(separator: "\r\n").utf8))
        if let stateLine {
            data.append(stateSequence(from: stateLine))
        }
        return Array(data)
    }

    /// Build the smallest useful VT state restoration from tmux format fields.
    /// Missing or out-of-range fields are ignored, which keeps the capture
    /// usable with older tmux versions while never accepting integer overflow.
    static func stateSequence(from line: String) -> Data {
        var fields: [String: String] = [:]
        for pair in line.split(separator: ",") {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { continue }
            fields[String(keyValue[0])] = String(keyValue[1])
        }

        let isOn: (String) -> Bool = { fields[$0] == "1" }
        let number: (String) -> Int? = { key in
            guard let value = fields[key].flatMap(Int.init), (0...65_535).contains(value) else {
                return nil
            }
            return value
        }

        var sequence = Data("\u{1b}[m".utf8)
        let upper = number("scroll_region_upper")
        let lower = number("scroll_region_lower")
        let paneHeight = number("pane_height")
        var restrictedRegion = false
        if let upper, let lower, lower >= upper {
            let isFullWindow = upper == 0 && paneHeight.map { $0 > 0 && lower == $0 - 1 } == true
            if !isFullWindow {
                sequence.append(Data("\u{1b}[\(upper + 1);\(lower + 1)r".utf8))
                restrictedRegion = true
            }
        }

        sequence.append(Data((isOn("wrap_flag") ? "\u{1b}[?7h" : "\u{1b}[?7l").utf8))
        sequence.append(Data((isOn("cursor_flag") ? "\u{1b}[?25h" : "\u{1b}[?25l").utf8))
        sequence.append(Data((isOn("insert_flag") ? "\u{1b}[4h" : "\u{1b}[4l").utf8))
        sequence.append(Data((isOn("keypad_cursor_flag") ? "\u{1b}[?1h" : "\u{1b}[?1l").utf8))
        sequence.append(Data((isOn("keypad_flag") ? "\u{1b}=" : "\u{1b}>").utf8))

        // Clear stale mouse modes before applying the mode tmux reports.
        sequence.append(Data("\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1005l\u{1b}[?1006l".utf8))
        if isOn("mouse_all_flag") {
            sequence.append(Data("\u{1b}[?1003h".utf8))
        } else if isOn("mouse_button_flag") {
            sequence.append(Data("\u{1b}[?1002h".utf8))
        } else if isOn("mouse_standard_flag") {
            sequence.append(Data("\u{1b}[?1000h".utf8))
        }
        if isOn("mouse_sgr_flag") {
            sequence.append(Data("\u{1b}[?1006h".utf8))
        } else if isOn("mouse_utf8_flag") {
            sequence.append(Data("\u{1b}[?1005h".utf8))
        }

        let originOn = isOn("origin_flag")
        sequence.append(Data((originOn ? "\u{1b}[?6h" : "\u{1b}[?6l").utf8))
        if let cursorX = number("cursor_x"), let cursorY = number("cursor_y") {
            let row = originOn && restrictedRegion ? max(0, cursorY - (upper ?? 0)) : cursorY
            sequence.append(Data("\u{1b}[\(row + 1);\(cursorX + 1)H".utf8))
        }
        return sequence
    }
}
