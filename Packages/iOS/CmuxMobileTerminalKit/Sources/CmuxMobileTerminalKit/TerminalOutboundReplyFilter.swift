public import Foundation

/// Who answers terminal queries for a surface, and therefore which bytes the
/// phone's own emulator may send back toward the PTY.
public enum TerminalLocalEmulation: Sendable, Equatable {
    /// A paired Mac is the terminal; everything the local mirror writes is
    /// spurious and dropped.
    case mirror
    /// The phone is the only emulator (SSH plain/tmux): replies, mouse,
    /// focus, and scroll bytes all go to the PTY.
    case authoritative
    /// A server-side emulator answers queries (SSH cmux-tui). Query replies
    /// are dropped so the program never sees two answers; user-driven
    /// reports (mouse, focus, alternate-scroll arrows) still go through.
    case inputOnly
}

/// Splits bytes a local terminal emulator wrote toward the PTY into query
/// replies and user-driven input.
///
/// Replies: device attributes (`CSI … c`), cursor/status reports
/// (`CSI … R`, `CSI … n`), mode reports (`CSI … $ y`), window reports
/// (`CSI … t`), every OSC (color and clipboard reads), and every DCS
/// (XTVERSION, DECRQSS). Everything else — SGR/X10 mouse, focus in/out,
/// arrow keys, plain text — is input.
public enum TerminalOutboundReplyFilter {
    /// Returns `bytes` with query replies removed.
    public static func removingQueryReplies(_ bytes: Data) -> Data {
        var output = Data()
        output.reserveCapacity(bytes.count)
        let b = [UInt8](bytes)
        var i = 0
        while i < b.count {
            guard b[i] == 0x1B, i + 1 < b.count else {
                output.append(b[i])
                i += 1
                continue
            }
            switch b[i + 1] {
            case UInt8(ascii: "["):
                let end = csiEnd(b, from: i + 2)
                let final = end < b.count ? b[end] : 0
                let sequence = b[i...min(end, b.count - 1)]
                if !isReplyCSI(final: final, body: b[(i + 2)..<min(end, b.count)]) {
                    output.append(contentsOf: sequence)
                }
                i = end + 1
            case UInt8(ascii: "]"), UInt8(ascii: "P"):
                // OSC / DCS: drop through the string terminator (BEL or ESC \).
                i = stringEnd(b, from: i + 2)
            default:
                output.append(b[i])
                i += 1
            }
        }
        return output
    }

    /// Index of the CSI final byte (0x40–0x7E) at or after `start`.
    private static func csiEnd(_ b: [UInt8], from start: Int) -> Int {
        var j = start
        while j < b.count, !(0x40...0x7E).contains(b[j]) { j += 1 }
        return j
    }

    /// Index just past the OSC/DCS terminator.
    private static func stringEnd(_ b: [UInt8], from start: Int) -> Int {
        var j = start
        while j < b.count {
            if b[j] == 0x07 { return j + 1 }
            if b[j] == 0x1B, j + 1 < b.count, b[j + 1] == UInt8(ascii: "\\") { return j + 2 }
            j += 1
        }
        return b.count
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
