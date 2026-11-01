public import Foundation

/// Removes what a display-only mirror's emulator writes toward the PTY on its
/// own behalf, keeping what the user typed.
///
/// A mirror (a viewing Mac's projection of another Mac's terminal) parses the
/// source terminal's output, so its Ghostty answers every query in that
/// stream and reports its own focus changes. The source terminal already
/// answered those queries and owns focus; forwarding the mirror's copies typed
/// stray text into the running program.
///
/// Dropped: device attributes (`CSI … c`), status reports (`CSI … n`), cursor
/// reports (`CSI row ; col R`, `CSI ? … R`), mode reports (`CSI … $ y`),
/// window reports (`CSI … t`), Kitty keyboard flags (`CSI ? … u`), focus
/// reports (`CSI I`, `CSI O`), and every terminated OSC, DCS and APC string.
/// Keys, pastes and mouse reports pass through. A legacy Shift+F3
/// (`CSI 1 ; 2 R`) is indistinguishable from a cursor report and is dropped
/// with them; unterminated strings (Alt+] typed alone) pass through. A
/// bracketed paste (`CSI 200 ~` … `CSI 201 ~`) passes through whole, so pasted
/// text that looks like a reply stays in the paste.
extension Data {
    private static let escape: UInt8 = 0x1B

    /// These emulator-written bytes without the mirror's own replies.
    public var removingTerminalMirrorReplies: Data {
        let bytes = [UInt8](self)
        var output = Data()
        output.reserveCapacity(bytes.count)
        var index = 0
        // Set once a string scan finds no terminator: none exists past that
        // point, so later `ESC ]` prefixes in the same write skip the rescan.
        var stringsUnterminated = false
        while index < bytes.count {
            guard bytes[index] == Self.escape, index + 1 < bytes.count else {
                output.append(bytes[index])
                index += 1
                continue
            }
            switch bytes[index + 1] {
            case UInt8(ascii: "["):
                guard let final = Self.csiFinalIndex(bytes, from: index + 2) else {
                    output.append(bytes[index])
                    index += 1
                    continue
                }
                if bytes[(index + 2)...final].elementsEqual(Self.pasteStart) {
                    let end = Self.pasteEnd(bytes, from: final + 1)
                    output.append(contentsOf: bytes[index..<end])
                    index = end
                    continue
                }
                if !Self.isReplyCSI(final: bytes[final], body: bytes[(index + 2)..<final]) {
                    output.append(contentsOf: bytes[index...final])
                }
                index = final + 1
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"):
                guard !stringsUnterminated, let end = Self.stringEnd(bytes, from: index + 2) else {
                    stringsUnterminated = true
                    output.append(bytes[index])
                    index += 1
                    continue
                }
                index = end
            default:
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    private static let pasteStart = Array("200~".utf8)
    private static let pasteEndMarker = Array("\u{1B}[201~".utf8)

    /// Index just past the bracketed paste's `ESC [ 201 ~`, or the end of the
    /// bytes when the paste continues in a later write.
    private static func pasteEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var cursor = start
        while cursor + pasteEndMarker.count <= bytes.count {
            if bytes[cursor..<(cursor + pasteEndMarker.count)].elementsEqual(pasteEndMarker) {
                return cursor + pasteEndMarker.count
            }
            cursor += 1
        }
        return bytes.count
    }

    private static func isReplyCSI(final: UInt8, body: ArraySlice<UInt8>) -> Bool {
        switch final {
        case UInt8(ascii: "c"), UInt8(ascii: "n"), UInt8(ascii: "t"):
            return true
        case UInt8(ascii: "R"):
            // An unmodified F3 (`CSI R`) has no body.
            return !body.isEmpty
        case UInt8(ascii: "y"):
            return body.last == UInt8(ascii: "$")
        case UInt8(ascii: "u"):
            // Kitty key events never start with `?`; the flags report does.
            return body.first == UInt8(ascii: "?")
        case UInt8(ascii: "I"), UInt8(ascii: "O"):
            return body.isEmpty
        default:
            return false
        }
    }

    /// Index of the CSI final byte, or nil when the sequence is incomplete or
    /// malformed.
    private static func csiFinalIndex(_ bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if (0x40...0x7E).contains(byte) { return cursor }
            guard (0x20...0x3F).contains(byte) else { return nil }
            cursor += 1
        }
        return nil
    }

    /// Index just past the OSC/DCS/APC terminator (BEL or ESC \), or nil when
    /// the string is unterminated.
    private static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start
        while cursor < bytes.count {
            if bytes[cursor] == 0x07 { return cursor + 1 }
            if bytes[cursor] == Self.escape, cursor + 1 < bytes.count, bytes[cursor + 1] == UInt8(ascii: "\\") {
                return cursor + 2
            }
            cursor += 1
        }
        return nil
    }
}
