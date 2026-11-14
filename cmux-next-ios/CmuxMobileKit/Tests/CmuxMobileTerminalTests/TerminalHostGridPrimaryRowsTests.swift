#if os(iOS) && DEBUG
import CmuxMobileArtifacts
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Live report (2026-11-14, Cloud machine, iPhone simulator): a second
/// device set the shared grid to 30×12 under Fit the smallest viewer, and
/// procps `top` (primary screen on that machine) showed on the phone with
/// rows missing: the clock and CPU rows updated, but "Tasks", "MiB Mem",
/// "MiB Swap" and the PID header row stayed blank while the Mac's own
/// screen had them (evidence-5e03cf49, sizing.md "top rows at 30x12").
///
/// `top` paints its whole screen once (`ESC[H ESC[2J`, then every row) and
/// from then on homes the cursor and rewrites only the rows that changed;
/// a row that did not change is a bare `\r\n`. So a row lost from the first
/// paint stays lost until its text changes.
///
/// With the shell's prompt marks (OSC 133, shell integration) the first
/// paint's `ESC[2J` is a clear at a prompt, which Ghostty does by scrolling
/// the screen into the scrollback; its cursor follows its row up, and on the
/// taller mirror it left the Mac's rows for the mirror's top.
///
/// The bytes are procps-ng top's own at 30×12 (recorded from a pty on a
/// Linux host): its first paint and two refreshes.
@MainActor
@Suite(.serialized) struct TerminalHostGridPrimaryRowsTests {
    typealias Rig = TerminalHostGridNoteTests.Screen

    static let firstPaint = "\u{1B}[?1h\u{1B}=\u{1B}[?25l\u{1B}[H\u{1B}[2J\u{1B}(B\u{1B}[mtop - 08:55:25 up 35 days, 21:\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\nTasks:\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[1m   5 \u{1B}(B\u{1B}[m\u{1B}[39;49mtotal,\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[1m   1 \u{1B}(B\u{1B}[m\u{1B}[39;49mrunning,\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\n%Cpu(s):\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[1m  0.0 \u{1B}(B\u{1B}[m\u{1B}[39;49mus,\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[1m  0.0 \u{1B}(B\u{1B}[m\u{1B}[39;49msy,\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[1m  0.\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\nMiB Mem :\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[1m 362500.2 \u{1B}(B\u{1B}[m\u{1B}[39;49mtotal,\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[1m 1031\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\nMiB Swap:\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[1m      0.0 \u{1B}(B\u{1B}[m\u{1B}[39;49mtotal,\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[1m     \u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\n\u{1B}[K\r\n\u{1B}[7m    PID USER      PR  NI \u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\n\u{1B}(B\u{1B}[m      1 rbx       20   0 \u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\n\u{1B}(B\u{1B}[m      5 rbx       20   0 \u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\n\u{1B}(B\u{1B}[m     12 rbx       20   0 \u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\n\u{1B}(B\u{1B}[m    401 rbx       20   0 \u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\n\u{1B}(B\u{1B}[m\u{1B}[1m    402 rbx       20   0 \u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K"

    /// A refresh: only the clock changed; every other row is a bare `\r\n`.
    static func refresh(_ clock: String) -> String {
        "\u{1B}[H\u{1B}(B\u{1B}[mtop - \(clock) up 35 days, 21:\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}(B\u{1B}[m\u{1B}[39;49m\u{1B}[K\r\n\r\n\r\n\r\n\r\n\u{1B}[K\r\n\r\n\r\n\r\n\r\n\r\n"
    }

    /// The Mac's 12 rows after the second refresh, as text. A row of exactly
    /// 30 columns loses its last one: top ends each row with `ESC[K`, which
    /// erases the cell under the cursor waiting to wrap (as on the Mac).
    static let expected = [
        "top - 08:55:27 up 35 days, 21",
        "Tasks:   5 total,   1 running",
        "%Cpu(s):  0.0 us,  0.0 sy,  0",
        "MiB Mem : 362500.2 total, 103",
        "MiB Swap:      0.0 total,",
        "",
        "    PID USER      PR  NI",
        "      1 rbx       20   0",
        "      5 rbx       20   0",
        "     12 rbx       20   0",
        "    401 rbx       20   0",
        "    402 rbx       20   0",
    ]

    /// A shell before `top`: lines, then the prompt `top` is typed at.
    /// `marks`: the shell marks its prompts (OSC 133, shell integration).
    static func shell(marks: Bool) -> String {
        let prompt = marks ? "\u{1B}]133;A\u{07}cmux@cmux:~$ \u{1B}]133;B\u{07}" : "cmux@cmux:~$ "
        let output = marks ? "\u{1B}]133;C\u{07}" : ""
        return "\u{1B}c" + prompt + "uname\r\n" + output + "Linux\r\n" + prompt + "top\r\n" + output
    }

    static func trimmed(_ line: Substring) -> String {
        String(line.reversed().drop(while: { $0 == " " }).reversed())
    }

    /// The Mac's rows in the mirror: its bottom 12 active rows.
    static func mirrorRows(_ rig: Rig) -> [String] {
        // The read leaves out blank rows at the end: pad to the mirror's rows.
        let lines = (rig.screen.surface.activeAreaText() ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(trimmed)
        let padded = lines + Array(repeating: "", count: max(0, rig.screen.surface.grid.rows - lines.count))
        return Array(padded.suffix(12))
    }

    /// The rows the page shows where the Mac's 12 rows are pinned: the
    /// viewport row under each grid row below the terminal area's top.
    static func shownRows(_ rig: Rig) -> [String] {
        guard let top = rig.terminalTop else { return [] }
        let surface = rig.screen.surface
        let cell = surface.cellSize.height
        guard cell > 0 else { return [] }
        let columns = max(1, surface.grid.columns)
        return (0..<12).map { row in
            let point = surface.convert(CGPoint(x: 1, y: top + (CGFloat(row) + 0.5) * cell), from: rig.screen.view)
            let viewportRow = Int(floor((point.y - surface.gridPadding.y) / cell))
            guard viewportRow >= 0, viewportRow < surface.grid.rows else { return "<outside the mirror: \(viewportRow)>" }
            let text = surface.viewportText(from: TerminalCellPoint(row: viewportRow, column: 0),
                                            to: TerminalCellPoint(row: viewportRow, column: columns - 1)) ?? ""
            return trimmed(Substring(text.replacingOccurrences(of: "\n", with: "")))
        }
    }

    @Test(arguments: [true, false])
    func topOnAShorterGridShowsEveryRow(shellMarks: Bool) async throws {
        await TerminalScreenTestLock.acquire()
        defer { TerminalScreenTestLock.release() }
        let rig = try await TerminalHostGridNoteTests.makeScreen()
        defer { rig.close() }
        rig.session.emit(.hostGrid(columns: 30, rows: 12))
        rig.session.emit(.hostGridOwner("Rig Mac"))
        rig.session.write(Self.shell(marks: shellMarks))
        try await TerminalPredictionInputTests.waitUntil(5) { (rig.screen.surface.activeAreaText() ?? "").contains("top") }

        rig.session.write(Self.firstPaint)
        try await TerminalPredictionInputTests.waitUntil(5) { (rig.screen.surface.activeAreaText() ?? "").contains("402") }
        rig.session.write(Self.refresh("08:55:26"))
        rig.session.write(Self.refresh("08:55:27"))
        try await TerminalPredictionInputTests.waitUntil(5) { (rig.screen.surface.activeAreaText() ?? "").contains("08:55:27") }
        try await TerminalPredictionInputTests.waitUntil(3) { Self.shownRows(rig) == Self.expected }

        let mirror = Self.mirrorRows(rig)
        let shown = Self.shownRows(rig)
        let grid = rig.screen.surface.grid
        let context = "mirror \(grid.columns)x\(grid.rows); mirror's last 12 rows \(mirror); shown \(shown)"
        for row in 0..<12 {
            #expect(mirror[row] == Self.expected[row], "the mirror's row \(row + 1) is not the Mac's: \(context)")
            #expect(shown[safe: row] == Self.expected[row], "the page's row \(row + 1) is not the Mac's: \(context)")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
