public import Foundation

/// Separates bytes a local terminal emulator wrote toward the PTY into query
/// replies and user-driven input.
///
/// Replies: device attributes (`CSI … c`), cursor/status reports
/// (`CSI … R`, `CSI … n`), mode reports (`CSI … $ y`), window reports
/// (`CSI … t`), every OSC (color and clipboard reads), and every DCS
/// (XTVERSION, DECRQSS). Everything else — SGR/X10 mouse, focus in/out,
/// arrow keys, plain text — is input.
extension Data {
    /// These emulator-written bytes with query replies removed.
    public var removingTerminalQueryReplies: Data {
        var output = Data()
        output.reserveCapacity(count)
        let b = [UInt8](self)
        var i = 0
        while i < b.count {
            guard b[i] == 0x1B, i + 1 < b.count else {
                output.append(b[i])
                i += 1
                continue
            }
            switch b[i + 1] {
            case UInt8(ascii: "["):
                let end = b.csiEnd(from: i + 2)
                let final = end < b.count ? b[end] : 0
                let sequence = b[i...Swift.min(end, b.count - 1)]
                if !Self.isReplyCSI(final: final, body: b[(i + 2)..<Swift.min(end, b.count)]) {
                    output.append(contentsOf: sequence)
                }
                i = end + 1
            case UInt8(ascii: "]"), UInt8(ascii: "P"):
                // OSC / DCS: drop through the string terminator (BEL or ESC \).
                i = b.stringEnd(from: i + 2)
            default:
                output.append(b[i])
                i += 1
            }
        }
        return output
    }

    private static func isReplyCSI(final: UInt8, body: ArraySlice<UInt8>) -> Bool {
        switch final {
        case UInt8(ascii: "c"), UInt8(ascii: "n"), UInt8(ascii: "t"):
            return true
        case UInt8(ascii: "R"):
            // CPR `CSI row ; col R`. An unmodified F3 (`CSI R`) has no body.
            return !body.isEmpty
        case UInt8(ascii: "y"):
            return body.last == UInt8(ascii: "$")
        default:
            return false
        }
    }
}

extension [UInt8] {
    /// Index of the CSI final byte (0x40–0x7E) at or after `start`.
    fileprivate func csiEnd(from start: Int) -> Int {
        var j = start
        while j < count, !(0x40...0x7E).contains(self[j]) { j += 1 }
        return j
    }

    /// Index just past the OSC/DCS terminator.
    fileprivate func stringEnd(from start: Int) -> Int {
        var j = start
        while j < count {
            if self[j] == 0x07 { return j + 1 }
            if self[j] == 0x1B, j + 1 < count, self[j + 1] == UInt8(ascii: "\\") { return j + 2 }
            j += 1
        }
        return count
    }
}
