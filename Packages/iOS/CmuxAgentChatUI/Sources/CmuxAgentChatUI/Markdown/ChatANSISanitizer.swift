/// Strips terminal control sequences from captured output so terminal and
/// tool cards render clean text.
///
/// Handles CSI sequences (`ESC [ ... final`), OSC sequences
/// (`ESC ] ... BEL` / `ESC ] ... ESC \`), bare two-character escapes, and
/// carriage-return progress lines (only the final `\r` segment of each
/// newline-delimited line is kept). Pure single-pass scanning; no regular
/// expressions on the hot path.
public struct ChatANSISanitizer: Sendable {
    /// Creates a sanitizer.
    public init() {}

    /// Returns `text` with escape sequences removed and `\r` progress
    /// overwrites collapsed to their final segment.
    ///
    /// - Parameter text: Raw captured terminal output.
    /// - Returns: Display-safe plain text.
    public func sanitized(_ text: String) -> String {
        collapseCarriageReturns(stripEscapes(text))
    }

    /// Removes ESC-introduced control sequences in one pass.
    private func stripEscapes(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{1B}") else { return text }
        let escape: Unicode.Scalar = "\u{1B}"
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar != escape {
                output.append(scalar)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { break }
            let introducer = scalars[index]
            if introducer == "[" {
                // CSI: parameter/intermediate bytes, then one final byte
                // in 0x40...0x7E.
                index += 1
                while index < scalars.count {
                    let value = scalars[index].value
                    index += 1
                    if value >= 0x40 && value <= 0x7E { break }
                }
            } else if introducer == "]" {
                // OSC: runs until BEL or the ESC \ string terminator.
                index += 1
                while index < scalars.count {
                    if scalars[index].value == 0x07 {
                        index += 1
                        break
                    }
                    if scalars[index] == escape,
                       index + 1 < scalars.count,
                       scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
            } else {
                // Bare two-character escape (ESC c, ESC =, ESC > ...).
                index += 1
            }
        }
        return String(output)
    }

    /// Keeps only the text after the last carriage return within each
    /// newline-delimited line, matching how a terminal would have rendered
    /// progress overwrites.
    private func collapseCarriageReturns(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let lastReturn = line.lastIndex(of: "\r") else { return line }
                return line[line.index(after: lastReturn)...]
            }
            .joined(separator: "\n")
    }
}
