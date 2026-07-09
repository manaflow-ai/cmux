#if DEBUG
internal import Foundation

extension String {
    /// Decodes backslash escape sequences in a line-based socket command
    /// argument back into their control characters.
    ///
    /// Socket commands are newline-framed, so a caller that needs to send a
    /// literal newline, carriage return, or tab in an argument encodes it with
    /// a backslash (`\n`, `\r`, `\t`, `\\`). This reverses that encoding:
    /// `\n`/`\r`/`\t` become their control characters, `\\` becomes a single
    /// backslash, any other `\x` is preserved verbatim (the backslash is kept
    /// and the character appended unchanged), and a trailing lone backslash is
    /// preserved. Used by the DEBUG `debug.terminal.simulate_type`
    /// (`simulate_type`) witness, the only caller of this decoding.
    public var socketTextEscapesDecoded: String {
        var out = ""
        var escaping = false
        for ch in self {
            if escaping {
                switch ch {
                case "n":
                    out.append("\n")
                case "r":
                    out.append("\r")
                case "t":
                    out.append("\t")
                case "\\":
                    out.append("\\")
                default:
                    out.append("\\")
                    out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping {
            out.append("\\")
        }
        return out
    }
}
#endif
