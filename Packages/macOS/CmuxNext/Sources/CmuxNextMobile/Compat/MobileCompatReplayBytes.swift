import CmuxNextDaemon
import Foundation

/// Turns a daemon `vt-state` replay into the bytes a shipped phone feeds its
/// Ghostty surface. The replay is Ghostty's complete VT export (screen,
/// scrollback, modes), so unlike the old Mac's byte tail it needs no grid.
/// Default colors and cursor shape travel beside the replay (`vt-state.colors`),
/// so they are re-applied here: OSC 10/11/12 before, DECSCUSR after. The
/// unfinished sequence the replay ended in (`pending`) goes last, so the
/// phone's next live chunk completes it.
enum MobileCompatReplayBytes {
    /// What the phone itself prepends to a snapshot (`terminalSnapshotReplacementBytes`).
    static let resetPrefix = Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)

    /// The snapshot for `mobile.terminal.replay` (`snapshot_data_b64`); the
    /// phone adds its own reset prefix.
    static func snapshot(_ replay: TerminalReplay) -> Data {
        var bytes = Data()
        if let colors = replay.colors {
            if let fg = colors.fg { bytes.append(osc(10, fg)) }
            if let bg = colors.bg { bytes.append(osc(11, bg)) }
            if let cursor = colors.cursor { bytes.append(osc(12, cursor)) }
        }
        bytes.append(replay.data)
        if let colors = replay.colors, let shape = cursorShape(colors.cursorStyle, blink: colors.cursorBlink ?? false) {
            bytes.append(Data("\u{1B}[\(shape) q".utf8))
        }
        bytes.append(replay.pending)
        return bytes
    }

    /// A live replacement (daemon `resized`): reset, then the snapshot.
    static func replacement(_ replay: TerminalReplay) -> Data {
        resetPrefix + snapshot(replay)
    }

    private static func osc(_ code: Int, _ color: String) -> Data {
        Data("\u{1B}]\(code);\(color)\u{1B}\\".utf8)
    }

    /// DECSCUSR: 1/2 block, 3/4 underline, 5/6 bar (odd = blinking).
    private static func cursorShape(_ style: String?, blink: Bool) -> Int? {
        let steady: Int
        switch style {
        case "block": steady = 2
        case "underline": steady = 4
        case "bar": steady = 6
        default: return nil
        }
        return blink ? steady - 1 : steady
    }
}
