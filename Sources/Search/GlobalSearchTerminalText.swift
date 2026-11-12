import Foundation

/// Text preparation for indexing terminal scrollback.
///
/// The bounded screen tail arrives as a VT reconstruction: it carries the
/// styling escape sequences Ghostty emits to redraw those rows. Those bytes
/// are noise for full-text search — they inflate the document, tokenize into
/// junk, and surface inside result snippets — so they are removed before the
/// text reaches the index.
enum GlobalSearchTerminalText {
    /// Strips VT escape sequences, leaving printable text, newlines and tabs.
    nonisolated static func strippedVT(_ text: String) -> String {
        guard text.contains("\u{1B}") || text.unicodeScalars.contains(where: isStrippableControl) else {
            return text
        }

        var output = String.UnicodeScalarView()
        output.reserveCapacity(text.unicodeScalars.count)
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        while let scalar = pending ?? iterator.next() {
            pending = nil
            guard scalar == "\u{1B}" else {
                if !isStrippableControl(scalar) {
                    output.append(scalar)
                }
                continue
            }

            guard let introducer = iterator.next() else { break }
            switch introducer {
            case "[":
                // CSI: parameter and intermediate bytes, then a final byte in 0x40...0x7E.
                while let next = iterator.next() {
                    if (0x40...0x7E).contains(next.value) { break }
                }
            case "]", "P", "X", "^", "_":
                // OSC/DCS/SOS/PM/APC run until BEL or the ST sequence (ESC \).
                while let next = iterator.next() {
                    if next == "\u{07}" { break }
                    if next == "\u{1B}" {
                        if let terminator = iterator.next(), terminator != "\\" {
                            // Not ST: hand the scalar back so it starts a new sequence.
                            pending = terminator == "\u{1B}" ? terminator : nil
                        }
                        break
                    }
                }
            default:
                // Everything else is ESC + zero or more intermediate bytes
                // (0x20...0x2F) + one final byte, so `ESC ( B` (charset
                // designation) consumes the designator while `ESC =` ends at
                // the introducer. A nested ESC starts a fresh sequence.
                if introducer == "\u{1B}" {
                    pending = introducer
                } else if (0x20...0x2F).contains(introducer.value) {
                    while let next = iterator.next() {
                        if next == "\u{1B}" {
                            pending = next
                            break
                        }
                        if !(0x20...0x2F).contains(next.value) { break }
                    }
                }
            }
        }

        return String(output)
    }

    /// FNV-1a over the scrollback, used to skip re-indexing unchanged panels.
    ///
    /// `Hasher` is seeded per process, which is fine in memory but makes the
    /// value untestable; this stays deterministic.
    nonisolated static func fingerprint(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0000_01b3
        }
        return hash
    }

    private nonisolated static func isStrippableControl(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value < 0x20 || scalar.value == 0x7F else { return false }
        return scalar != "\n" && scalar != "\t"
    }
}
