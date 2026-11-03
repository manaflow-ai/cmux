#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// User report (2026-10-21, iPhone over 5G): opening a tab running Claude
/// Code showed an almost black screen with only the spinner line, the cursor
/// and a few status digits, at their final places; the whole screen came a
/// moment later.
///
/// The phone's mirror is taller than the Mac's screen, so its primary screen
/// starts `offset` rows down (`TerminalRowShift`: the reset is followed by
/// `offset` line feeds). Entering the alternate screen copies the primary
/// cursor, and the daemon's replay of a TUI draws its rows from the cursor
/// (it starts with the modes and `\r\r\n`, no cursor home). The replay's rows
/// landed below the rows a TUI shows, while the live updates, positioned
/// absolutely, landed on them. Through the real Ghostty surface: the replay's
/// rows must be the TUI's top rows.
@MainActor
@Suite(.serialized) struct TerminalAltScreenReplaySurfaceTests {
    /// The Mac's screen.
    static let remoteRows = 12

    @MainActor final class Rig {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 2000))
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 1800))
        var shift = TerminalRowShift()

        init() {
            window.isHidden = false
            window.addSubview(surface)
        }

        var offset: Int { max(0, surface.grid.rows - TerminalAltScreenReplaySurfaceTests.remoteRows) }

        /// Feeds `text` the way the screen does: through the row shift first.
        func feed(_ text: String) async {
            let bytes = shift.filter(Data(text.utf8), offset: offset, remoteRows: TerminalAltScreenReplaySurfaceTests.remoteRows)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                surface.feed(bytes, completion: { done.resume() })
            }
        }

        /// Every row of the active area, padded to the grid (the text read
        /// ends at the last row with text).
        var allRows: [String] {
            let text = surface.activeAreaText() ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            return lines + Array(repeating: "", count: max(0, surface.grid.rows - lines.count))
        }

        /// The TUI's rows (the top `remoteRows` of the mirror), trailing blanks trimmed.
        var tuiRows: [String] {
            let text = surface.activeAreaText() ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
            return Array((lines + Array(repeating: "", count: TerminalAltScreenReplaySurfaceTests.remoteRows)).prefix(TerminalAltScreenReplaySurfaceTests.remoteRows))
        }
    }

    /// The daemon's replay of a Claude-shaped full-screen TUI (vt-state
    /// `data`): modes, the alternate screen, tab stops on the cursor's row,
    /// then the rows from the cursor, then the cursor's place.
    static let replay = "\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?1049h\u{1B}[?2004h\u{1B}[3g\u{1B}[9G\u{1B}H\r\r\n"
        + " Claude Code v2\r\n\r\n> Write an essay\r\n\r\n* Phosphor, Paper, and Pixels\r\n  Introduction\r\n"
        + "* Levitating (49s)\r\n----\r\n> \r\n----\r\n  bypass permissions on"
        + "\u{1B}[10;3H"
    /// A live update after the replay: Claude's spinner line, positioned absolutely.
    static let spinner = "\u{1B}[?2026h\u{1B}[?25l\u{1B}[8;1H\u{1B}[K* Levitating (50s)\u{1B}[10;3H\u{1B}[?25h\u{1B}[?2026l"

    @Test func aTUIReplayFillsTheRowsTheTUIShows() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        try #require(rig.offset > 0, "the mirror is taller than the Mac's screen, as on the phone")
        // A shell's screen first (the tab's primary screen), as on the Mac.
        await rig.feed("\u{1B}c$ claude\r\n")
        // The attach: the session's reset, the replay, then live output.
        await rig.feed("\u{1B}c")
        await rig.feed(Self.replay)
        // Row 0 marked, so the rows are counted from the screen's top whatever
        // the text read does with a blank first row.
        await rig.feed("\u{1B}7\u{1B}[1;1HTOP\u{1B}8")
        let rows = rig.tuiRows
        #expect(rows[0] == "TOP", "\(rows)")
        #expect(rows[1] == "Claude Code v2", "\(rows)")
        #expect(rows[5] == "* Phosphor, Paper, and Pixels", "\(rows)")
        #expect(rows[7] == "* Levitating (49s)", "\(rows)")
        #expect(rows[11] == "bypass permissions on", "\(rows)")
        await rig.feed(Self.spinner)
        let live = rig.tuiRows
        #expect(live[1] == "Claude Code v2", "\(live)")
        #expect(live[7] == "* Levitating (50s)", "\(live)")
        // Nothing of the replay below the TUI's rows.
        let below = rig.allRows.dropFirst(Self.remoteRows)
        #expect(below.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(Array(below))")
    }

    /// Leaving the alternate screen puts the shell's screen back where it was.
    @Test func leavingTheTUIKeepsTheShellOnTheBottomRows() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        try #require(rig.offset > 0)
        await rig.feed("\u{1B}c")
        await rig.feed("$ claude")
        await rig.feed(Self.replay)
        await rig.feed("\u{1B}[?1049l\r\n$ ")
        let lines = rig.allRows
        // The shell's first row is the mirror's row `offset` (the Mac's row 0).
        #expect(lines.count > rig.offset + 1)
        #expect(lines[rig.offset] == "$ claude", "\(lines.suffix(Self.remoteRows + 2))")
        #expect(lines[rig.offset + 1] == "$", "\(lines.suffix(Self.remoteRows + 2))")
    }

    /// Mode 1047 copies the cursor both ways (no save): back on the shell
    /// it is on the shell's rows again.
    @Test func mode1047CopiesTheCursorBackToTheShellsRows() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        try #require(rig.offset > 0)
        await rig.feed("\u{1B}c")
        await rig.feed("$ less\r\n")
        await rig.feed("\u{1B}[?1047h\u{1B}[3;1Hpage")
        let tui = rig.tuiRows
        #expect(tui[2] == "page", "\(tui)")
        await rig.feed("\u{1B}[?1047l\r\n$ ")
        let lines = rig.allRows
        #expect(lines[rig.offset] == "$ less", "\(lines.suffix(Self.remoteRows + 2))")
        // The cursor came back on the Mac's row 2 (+ offset), then a new line.
        #expect(lines[rig.offset + 3] == "$", "\(lines.suffix(Self.remoteRows + 2))")
    }

    /// Clear Screen and Scrollback through the real Ghostty mirror: the daemon's erase
    /// (`IND`s from its last row, then `ESC[3J`) leaves the prompt and nothing of the old
    /// output, neither in the scrollback nor in the rows above the Mac's screen.
    @Test func clearHistoryLeavesOnlyThePromptOnThePhone() async {
        let rig = Rig()
        await rig.feed("\u{1B}c")
        await rig.feed((1...60).map { "old-\($0)" }.joined(separator: "\r\n") + "\r\n$ ")
        #expect(rig.surface.screenText()?.contains("old-30") == true)
        // The daemon's clear with the prompt on the Mac's last row: up to the top, then 3J.
        let rows = TerminalAltScreenReplaySurfaceTests.remoteRows
        await rig.feed("\u{1B}[\(rows);1H" + String(repeating: "\u{1B}D", count: rows - 1) + "\u{1B}[3J\u{1B}[1;3H")
        let text = rig.surface.screenText() ?? ""
        #expect(!text.contains("old-"))
        #expect(text.contains("$"))
    }
}
#endif
