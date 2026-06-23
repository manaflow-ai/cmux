import Foundation

/// Strips a leading ANSI escape sequence from text committed through
/// `NSTextInputClient`.
///
/// External accessibility and dictation tools should commit plain text, but
/// some inject a leading escape sequence first. Stripping those bytes on the
/// committed-text path stops them leaking into the PTY as literals.
///
/// The scan operates byte-faithfully over `Array(text.utf8)` and recognizes the
/// ANSI C0 escape introducer (`ESC`, `0x1B`), the C1 CSI introducer encoded as
/// the UTF-8 byte pair `C2 9B` (U+009B), and the escape families that follow:
/// CSI (`ESC [`), SS3 (`ESC O`), and the string sequences DCS/OSC/PM/APC
/// (`ESC P`/`]`/`^`/`_`), each terminated by `BEL` or `ST` per the legacy
/// terminal grammar. Only a leading run of such sequences is consumed; the first
/// non-escape byte stops the scan and the remainder is returned verbatim.
///
/// A value type with a single instance method rather than a static-only
/// namespace: it owns no state and is created at the call site each time it is
/// needed.
public struct TerminalExternalCommittedTextSanitizer {
    public init() {}

    /// Returns `text` with any leading ANSI escape sequence(s) removed.
    ///
    /// - Parameter text: The text committed by an external input client.
    /// - Returns: `text` unchanged when it does not begin with an escape
    ///   sequence, the empty string when the entire input was escape bytes, or
    ///   the suffix beginning at the first non-escape byte.
    public func sanitize(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return text }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                index = consumeLeadingEscapeSequence(in: bytes, from: index)
                continue
            }

            if byte == 0xC2 {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x9B {
                    // U+009B (C1 CSI) is encoded as the UTF-8 byte pair C2 9B.
                    index = consumeLeadingCSISequence(in: bytes, from: next + 1)
                    continue
                }
            }

            break
        }

        if index == 0 {
            return text
        }

        guard index < bytes.count else { return "" }
        return String(decoding: bytes[index...], as: UTF8.self)
    }

    private func consumeLeadingEscapeSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        let next = start + 1
        guard next < bytes.count else { return bytes.count }

        switch bytes[next] {
        case 0x5B:
            // CSI: ESC [ ... final
            return consumeLeadingCSISequence(in: bytes, from: next + 1)
        case 0x4F:
            // SS3: ESC O final
            return min(bytes.count, next + 2)
        case 0x50, 0x5D, 0x5E, 0x5F:
            // DCS/OSC/PM/APC: consume until BEL/ST or EOF.
            return consumeLeadingEscapedStringSequence(in: bytes, from: next + 1)
        default:
            // Single-character escape.
            return min(bytes.count, next + 1)
        }
    }

    private func consumeLeadingCSISequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if (0x20...0x3F).contains(byte) {
                index += 1
                continue
            }

            if (0x40...0x7E).contains(byte) {
                return index + 1
            }

            break
        }

        return index
    }

    private func consumeLeadingEscapedStringSequence(
        in bytes: [UInt8],
        from start: Int
    ) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return index + 1
            }

            if byte == 0x1B {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x5C {
                    return next + 1
                }
                return index
            }

            if byte < 0x20 || byte == 0x7F {
                return index + 1
            }

            index += 1
        }

        return bytes.count
    }
}
