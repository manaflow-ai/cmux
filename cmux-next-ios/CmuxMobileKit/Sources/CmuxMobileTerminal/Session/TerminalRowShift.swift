import Foundation

/// Maps a remote terminal's primary screen onto the bottom rows of the phone's
/// taller mirror.
///
/// The phone's Ghostty surface is the visible rows plus scroll margins (about
/// 150 rows), while the Mac's terminal is sized to the phone's TUI grid
/// (about 40). Linear output does not care, but absolute positions do: the
/// daemon's replay ends with `CUP <row>;<col>` for its own screen, and a shell
/// redraw can address rows directly. Unshifted, row 40 of the Mac landed in
/// the middle of the mirror: the prompt sat mid-screen under old scrollback,
/// and typing overwrote it.
///
/// So on the primary screen the Mac's row `r` is the mirror's row
/// `r + offset` (`offset` = mirror rows - remote rows):
/// - a reset (`ESC c`) is followed by `offset` line feeds, so the remote
///   screen starts at the mirror's row `offset + 1`;
/// - `CUP`/`HVP` (`H`, `f`) and `VPA` (`d`) rows gain `offset`;
/// - `ED 3` (`ESC[3J`, erase saved lines) also erases the `offset` rows above the
///   remote screen, which are history on the Mac but screen rows here;
/// - `DECSTBM` (`r`) with explicit margins gains `offset`, except the full
///   remote screen, which stays a full-screen region so lines that scroll off
///   the top still reach the scrollback.
/// - A region whose top is the remote screen's first row (`1;B`) keeps the
///   mirror's first row as its top (`1;B+offset`). On the Mac, a line that
///   scrolls out of a region starting at the top of the screen goes to the
///   scrollback; that is how inline TUIs such as Codex CLI print their history
///   above their live area (`ESC[1;Nr`, then `\r\n` per line). Shifted to
///   `offset+1;B+offset` the region no longer started at the top of the mirror,
///   so every such line was discarded: the phone kept only a screen's worth
///   of the session while the Mac scrolled back to its first line (user
///   report, 2026-10-14). With the mirror's top row as the region top, the
///   lines move up through the rows above the Mac's screen and on into the
///   scrollback, in the same order as on the Mac.
///
/// The alternate screen (DEC modes 47, 1047, 1049) is drawn from the mirror's
/// top and clipped to the TUI rows, so nothing is shifted there, but its
/// scroll margins are the Mac's rows (set on entering it, and for a TUI's
/// margin reset): a line feed on the Mac's last row scrolls, as on the Mac.
/// Leaving it resets the scroll margins a TUI set for its rows. Escape
/// sequences split across chunks are held until complete; OSC, DCS, APC, PM
/// and SOS strings pass through untouched.
public struct TerminalRowShift: Sendable {
    public private(set) var isAlternate = false
    private var state: State = .ground
    /// Bytes of an escape sequence not yet complete.
    private var held: [UInt8] = []

    private enum State: Sendable { case ground, escape, csi, string, stringEscape }

    public init() {}

    /// Rewrites `data` for a mirror `offset` rows taller than the remote
    /// screen of `remoteRows` rows. An offset of 0 passes everything through.
    public mutating func filter(_ data: Data, offset: Int, remoteRows: Int) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(data.count + 16)
        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B {
                    state = .escape
                    held = [byte]
                } else {
                    out.append(byte)
                }
            case .escape:
                held.append(byte)
                switch byte {
                case UInt8(ascii: "["):
                    state = .csi
                case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
                    state = .string
                    out += held
                    held = []
                case UInt8(ascii: "c"):
                    state = .ground
                    out += held
                    held = []
                    isAlternate = false
                    if offset > 0 { out += [UInt8](repeating: 0x0A, count: offset) }
                case 0x20...0x2F:
                    break  // intermediate (ESC ( B and the like): wait for the final byte
                default:
                    state = .ground
                    out += held
                    held = []
                }
            case .csi:
                held.append(byte)
                if (0x40...0x7E).contains(byte) {
                    out += rewrite(held, offset: offset, remoteRows: remoteRows)
                    held = []
                    state = .ground
                } else if held.count > 64 {
                    // Not a sequence worth parsing: let the terminal judge it.
                    out += held
                    held = []
                    state = .ground
                }
            case .string:
                out.append(byte)
                if byte == 0x07 { state = .ground } else if byte == 0x1B { state = .stringEscape }
            case .stringEscape:
                out.append(byte)
                state = byte == UInt8(ascii: "\\") ? .ground : (byte == 0x1B ? .stringEscape : .string)
            }
        }
        return Data(out)
    }

    /// One complete CSI sequence (`ESC [ params final`).
    private mutating func rewrite(_ sequence: [UInt8], offset: Int, remoteRows: Int) -> [UInt8] {
        guard let final = sequence.last else { return sequence }
        let body = sequence[2..<(sequence.count - 1)]
        let text = String(decoding: body, as: UTF8.self)
        if text.hasPrefix("?"), final == UInt8(ascii: "h") || final == UInt8(ascii: "l") {
            let modes = text.dropFirst().split(separator: ";").compactMap { Int($0) }
            guard modes.contains(where: { [47, 1047, 1049].contains($0) }) else { return sequence }
            let wasAlternate = isAlternate
            isAlternate = final == UInt8(ascii: "h")
            let resetMargins = Self.saved(Self.csi("", UInt8(ascii: "r")))
            // Scroll margins are shared by both screens. A TUI's full-screen
            // region (`1;remoteRows`, unshifted there) is only the mirror's top
            // rows: back on the primary screen, output at the bottom row would
            // never scroll again. Reset the margins, keeping the cursor
            // (DECSTBM homes it).
            if !isAlternate, offset > 0 {
                // Modes 47 and 1047 copy the alternate screen's cursor (the
                // Mac's row r, unshifted) to the primary screen, where the Mac's
                // row r is the mirror's row r + offset. 1049 restores the cursor
                // it saved on the primary screen, already shifted.
                let copiesCursor = wasAlternate && !modes.contains(1049)
                return sequence + resetMargins + (copiesCursor ? Self.csi("\(offset)", UInt8(ascii: "B")) : [])
            }
            if isAlternate, offset > 0 {
                // Entering it copies the primary screen's cursor, the Mac's
                // row r at the mirror's row r + offset; on the alternate
                // screen the Mac's row r is the mirror's row r. Up by
                // `offset`, so a program that draws from the cursor draws
                // where the Mac does. The daemon's replay of a TUI does: its
                // modes, the switch, then its rows from the cursor (`\r\r\n`
                // ...), with no cursor home. Left below, the replay's rows
                // landed under the rows the phone shows while the live
                // updates (positioned) landed on them: a black screen with a
                // few changed cells (user report 2026-10-21, Claude Code).
                // Margins reset first, so the move is not stopped at a region top.
                let up = wasAlternate ? [] : resetMargins + Self.csi("\(offset)", UInt8(ascii: "A"))
                // The alternate screen is drawn from the mirror's top: its
                // margins are the Mac's rows, so a line feed on the Mac's last
                // row scrolls (less scrolls that way, with no margins of its own;
                // on the full mirror it moved below the rows shown).
                return sequence + up + Self.saved(Self.csi("1;\(remoteRows)", UInt8(ascii: "r")))
            }
            return sequence
        }
        if isAlternate, offset > 0, final == UInt8(ascii: "r"),
           body.allSatisfy({ (0x30...0x39).contains($0) || $0 == UInt8(ascii: ";") }) {
            // A TUI's margins are within the Mac's screen, not the mirror's:
            // a missing or zero bottom (a reset, `ESC[;r`, `ESC[5r`) is the
            // Mac's last row, and none goes past it.
            let params = text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            let top = max(1, params.first ?? 0)
            let bottom = params.count > 1 && params[1] > 0 ? min(params[1], remoteRows) : remoteRows
            return Self.csi("\(top);\(bottom)", final)
        }
        guard offset > 0, !isAlternate,
              body.allSatisfy({ (0x30...0x39).contains($0) || $0 == UInt8(ascii: ";") }) else { return sequence }
        let params = text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        func row(_ index: Int) -> Int { index < params.count ? max(1, params[index] ?? 1) : 1 }
        switch final {
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            let column = params.count > 1 ? (params[1] ?? 1) : 1
            return Self.csi("\(row(0) + offset);\(max(1, column))", final)
        case UInt8(ascii: "d"):
            return Self.csi("\(row(0) + offset)", final)
        case UInt8(ascii: "J") where text == "3":
            // Erase Saved Lines (the Mac's Clear Screen and Scrollback sends it, as does
            // `clear`): on the Mac every row above its screen is history and goes. Here
            // the `offset` rows above the Mac's screen are the mirror's own screen rows,
            // which `3J` keeps; erase them too, cursor kept, so the phone clears as the Mac does.
            return sequence + Self.saved(Self.csi("\(offset);9999", UInt8(ascii: "H")) + Self.csi("1", UInt8(ascii: "J")))
        case UInt8(ascii: "r"):
            guard !text.isEmpty else { return sequence }
            let top = row(0)
            let bottom = params.count > 1 ? (params[1] ?? remoteRows) : remoteRows
            if top == 1, bottom >= remoteRows { return Self.csi("", final) }
            if top == 1 { return Self.csi("1;\(bottom + offset)", final) }
            return Self.csi("\(top + offset);\(bottom + offset)", final)
        default:
            return sequence
        }
    }

    /// `sequence` with the cursor kept (DECSTBM homes it).
    private static func saved(_ sequence: [UInt8]) -> [UInt8] {
        [0x1B, UInt8(ascii: "7")] + sequence + [0x1B, UInt8(ascii: "8")]
    }

    private static func csi(_ params: String, _ final: UInt8) -> [UInt8] {
        [0x1B, UInt8(ascii: "[")] + Array(params.utf8) + [final]
    }
}
