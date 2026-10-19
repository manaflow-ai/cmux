import Foundation

/// Text from another process, made safe to print to a terminal.
///
/// The app on the socket (or anything listening there) controls every string
/// it sends back: error messages, actions, reasons, details, identity fields.
/// An escape sequence in them can retitle the window, clear the screen,
/// recolor or hide text, or write to the clipboard; a carriage return or a
/// Unicode line separator can overwrite or forge lines. The CLI prints such
/// text only after passing it through `printable`.
enum CLITerminalText {
    /// `text` without C0 and C1 controls (ESC, BEL, CSI, CR, DEL, NEL),
    /// bidirectional marks, overrides, and isolates, and Unicode line and
    /// paragraph separators. With `keepingLineBreaks`, LF and tab survive so
    /// multi-line messages keep their layout; otherwise they are dropped too,
    /// for text that must stay on one line.
    static func printable(_ text: String, keepingLineBreaks: Bool = false) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { scalar in
            if keepingLineBreaks, scalar == "\n" || scalar == "\t" { return true }
            if scalar.properties.generalCategory == .control { return false }
            switch scalar.value {
            case 0x061C, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069: return false
            default: return true
            }
        })
        return String(scalars)
    }
}
