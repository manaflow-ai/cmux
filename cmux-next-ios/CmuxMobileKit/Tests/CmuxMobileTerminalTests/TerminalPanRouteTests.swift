#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12: "this terminal projection nigh unusable due to me scroll
/// and thumb land on subagent depiction", then on less and man no longer
/// scrolling: "Okay. But can't we do something here?". A drag over the
/// terminal is a scroll (``TerminalPanRoute``): never a keystroke into an
/// agent, and cursor keys into a pager, as a Mac trackpad in Ghostty. These
/// feed the modes each program sets on start, captured from its PTY (Claude
/// Code 2.1.322 with and without `CLAUDE_CODE_DISABLE_MOUSE`, its inline
/// renderer, Codex, less, vim, a plain shell), with the foreground program
/// the Mac reports for it, into a real Ghostty mirror surface, then drag ten
/// rows through the same path a finger takes, and count what reaches the remote.
@MainActor
@Suite(.serialized) struct TerminalPanRouteTests {
    struct Program: CustomStringConvertible, Sendable {
        let name: String
        let modes: String
        /// `process-info` `foreground_executable` (nil: not known yet).
        let foreground: String?
        let route: TerminalPanRoute
        /// The arrow a drag toward older content sends (cursorKeys).
        var arrow: String = "\u{1b}OA"
        var description: String { name }
    }

    nonisolated static let claudeNoMouse = "\u{1b}[?1049h\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?2031h"
    nonisolated static let lessModes = "\u{1b}[?1049h\u{1b}[?1h\u{1b}="

    nonisolated static let programs: [Program] = [
        // Claude Code's full-screen renderer: alt screen, any-motion SGR mouse.
        Program(name: "claude-code", modes: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?2031h",
                foreground: "claude", route: .wheelReports),
        // Claude Code with mouse capture off: alt screen, no mouse reporting.
        // Ghostty's alternate scroll made each row of drag an arrow key here:
        // up walked the prompt history, down went into the agent list. However
        // the Mac names it (the native binary, its version file, node, a
        // wrapper script, ssh to another machine, not answered yet), nothing.
        Program(name: "claude-code-no-mouse", modes: claudeNoMouse, foreground: "claude", route: .none),
        Program(name: "claude-code-no-mouse-version-binary", modes: claudeNoMouse, foreground: "2.1.322", route: .none),
        Program(name: "claude-code-no-mouse-node", modes: claudeNoMouse, foreground: "/usr/local/bin/node", route: .none),
        Program(name: "claude-code-no-mouse-wrapper", modes: claudeNoMouse, foreground: "sh", route: .none),
        Program(name: "claude-code-no-mouse-ssh", modes: claudeNoMouse, foreground: "ssh", route: .none),
        Program(name: "claude-code-no-mouse-unknown", modes: claudeNoMouse, foreground: nil, route: .none),
        // Claude Code's inline renderer: the primary screen (its transcript is
        // the shell's scrollback, the agent list its bottom rows).
        Program(name: "claude-code-inline", modes: "\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?2031h\u{1b}[?25l",
                foreground: "claude", route: .localScrollback),
        // Codex: alt screen, any-motion SGR mouse, alternate scroll off.
        Program(name: "codex", modes: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1006h\u{1b}[?1007l\u{1b}[?2004h",
                foreground: "codex", route: .wheelReports),
        // less: alt screen, application cursor keys (DECCKM): ESC O A per row.
        Program(name: "less", modes: lessModes, foreground: "less", route: .cursorKeys),
        // git log: git leads the job, its pager less draws.
        Program(name: "git-log", modes: lessModes, foreground: "/usr/bin/git", route: .cursorKeys),
        // vim without `mouse=a`: alt screen, application cursor keys, bracketed paste.
        Program(name: "vim", modes: "\u{1b}[?1049h\u{1b}[?1h\u{1b}=\u{1b}[?2004h", foreground: "vim", route: .cursorKeys),
        // A pager in normal cursor-key mode gets ESC [ A.
        Program(name: "more", modes: "\u{1b}[?1049h", foreground: "more", route: .cursorKeys, arrow: "\u{1b}[A"),
        // A pager with alternate scroll turned off gets nothing, as on the Mac.
        Program(name: "less-1007-off", modes: lessModes + "\u{1b}[?1007l", foreground: "less", route: .cursorKeys, arrow: ""),
        // less before the Mac answered: nothing yet.
        Program(name: "less-unknown", modes: lessModes, foreground: nil, route: .none),
        // A plain shell: the primary screen, the phone's own scrollback.
        Program(name: "shell", modes: "\u{1b}[?2004h", foreground: nil, route: .localScrollback),
    ]

    @MainActor final class Rig {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        var sent = Data()

        init() {
            window.isHidden = false
            window.addSubview(surface)
            surface.onInput = { [weak self] data in self?.sent.append(data) }
        }

        func feed(_ text: String) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                surface.feed(Data(text.utf8), completion: { done.resume() })
            }
        }

        /// Lets bytes Ghostty wrote from its own thread reach `onInput`.
        func settle() async {
            for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }
        }

        /// The finger on the bottom row, where Claude Code draws its agent list.
        var thumb: CGPoint {
            CGPoint(x: surface.gridPadding.x + 4.5 * surface.cellSize.width,
                    y: surface.gridPadding.y + (Double(max(1, surface.grid.rows)) - 0.5) * surface.cellSize.height)
        }

        /// A slow ten-row drag down (toward older content): the moves a pan
        /// reports, through ``TerminalTUIScroll`` and the surface's drag path,
        /// as the controller sends them. `rows` carries on into a fling.
        @discardableResult
        func pan(rows count: Int = 10, rows: inout TerminalAlternateScroll.Rows) -> Int {
            let row = surface.cellSize.height
            var scroll = TerminalTUIScroll()
            scroll.began()
            rows.began()
            var reached = 0
            for step in 1...(count * 4) {
                let wheel = scroll.moved(translationY: CGFloat(step) * row / 4, velocityY: 150)
                if let wheel, surface.dragWheel(wheel, at: thumb, rows: &rows) { reached += 1 }
            }
            return reached
        }

        func pan(rows count: Int = 10) {
            var rows = TerminalAlternateScroll.Rows()
            pan(rows: count, rows: &rows)
        }

        var text: String { String(decoding: sent, as: UTF8.self) }

        func count(_ sequence: String) -> Int { text.components(separatedBy: sequence).count - 1 }

        var arrowKeys: Int {
            ["\u{1b}[A", "\u{1b}[B", "\u{1b}OA", "\u{1b}OB"].reduce(0) { $0 + count($1) }
        }

        var wheelReports: Int { count("\u{1b}[<6") }
    }

    @Test(arguments: programs)
    func aDragScrollsTheAppItsWay(program: Program) async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        rig.surface.foregroundProgram = program.foreground
        await rig.feed(program.modes + "\u{1b}[H\u{1b}[2Jtranscript\r\n")
        #expect(rig.surface.panRoute == program.route)
        rig.sent = Data()
        let start = ContinuousClock.now
        rig.pan()
        let encode = ContinuousClock.now - start
        await rig.settle()
        print("pan-route program=\(program.name) route=\(program.route) bytes=\(rig.sent.count) arrows=\(rig.arrowKeys) wheelReports=\(rig.wheelReports) encode=\(encode)")
        switch program.route {
        case .wheelReports:
            // The app scrolls its own history: one report per row (a slow drag).
            #expect(rig.arrowKeys == 0)
            #expect((9...10).contains(rig.wheelReports))
        case .cursorKeys where program.arrow.isEmpty:
            #expect(rig.sent.isEmpty)
        case .cursorKeys:
            // One key per row moved, the older-content direction, and nothing else.
            #expect(rig.text == String(repeating: program.arrow, count: 10))
        case .none, .localScrollback:
            #expect(rig.sent.isEmpty)
        }
    }

    /// The regression Leo hit: a thumb's drag over Claude Code's inline frame
    /// (the primary screen, the agent list on its bottom rows) and over its
    /// full-screen renderer without mouse capture sends not one byte, drags
    /// and flings both, whatever the Mac names its program.
    @Test(arguments: ["claude", "node", "2.1.322", "sh", nil] as [String?])
    func aDragOverClaudeCodeSendsNothing(foreground: String?) async throws {
        for modes in ["\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?2031h\u{1b}[?25l", Self.claudeNoMouse] {
            let rig = Rig()
            try #require(rig.surface.surface != nil)
            rig.surface.foregroundProgram = foreground
            await rig.feed(modes + "\u{1b}[H\u{1b}[2J> \r\n\u{1b}[24;1H  2 background agents")
            rig.sent = Data()
            var rows = TerminalAlternateScroll.Rows()
            #expect(rig.pan(rows: 10, rows: &rows) == 0)
            var fling = try #require(TerminalTUIMomentum(velocityY: 2400))
            while let wheel = fling.step(dt: 1.0 / 60) { _ = rig.surface.dragWheel(wheel, at: rig.thumb, rows: &rows) }
            await rig.settle()
            #expect(rig.sent.isEmpty, "\(foreground ?? "nil") \(modes.debugDescription)")
        }
    }

    /// man on macOS is a shell script: its job leader is `sh` running
    /// `/usr/bin/man`, with less under it, so `foreground_executable` reads
    /// `/bin/sh`. The Mac now also names the job's program
    /// (`foreground_program`: `man`), and a ten-row drag sends ten keys. The
    /// same reply without it (a Mac from before) still sends none, and a
    /// wrapper script for Claude Code (`foreground_program` `claude`) or
    /// node running it sends none either.
    @Test(arguments: [
        (#"{"ok":true,"data":{"foreground_executable":"/bin/sh","foreground_program":"man"}}"#, 10),
        (#"{"ok":true,"data":{"foreground_executable":"/bin/sh"}}"#, 0),
        (#"{"ok":true,"data":{"foreground_executable":"/bin/sh","foreground_program":"sh"}}"#, 0),
        (#"{"ok":true,"data":{"foreground_executable":"/bin/sh","foreground_program":"claude"}}"#, 0),
        (#"{"ok":true,"data":{"foreground_executable":"/usr/local/bin/node","foreground_program":"node"}}"#, 0),
    ] as [(String, Int)])
    func aDragOverManThroughShScrollsIt(reply: String, keys: Int) async throws {
        let info = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        rig.surface.foregroundProgram = TerminalAlternateScroll.program(processInfo: info)
        await rig.feed(Self.lessModes + "\u{1b}[H\u{1b}[2JLS(1)\r\n")
        rig.sent = Data()
        rig.pan()
        await rig.settle()
        print("pan-route man-through-sh reply=\(reply) arrows=\(rig.arrowKeys) bytes=\(rig.sent.count)")
        #expect(rig.text == String(repeating: "\u{1b}OA", count: keys))
    }

    /// A fling in less goes on as whole rows, one key each, and ends on a row:
    /// nothing of a row is left for the next drag.
    @Test func aFlingInLessEndsOnARow() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        rig.surface.foregroundProgram = "less"
        await rig.feed(Self.lessModes)
        rig.sent = Data()
        var rows = TerminalAlternateScroll.Rows()
        rig.pan(rows: 3, rows: &rows)
        var fling = try #require(TerminalTUIMomentum(velocityY: 1200))
        var travel: CGFloat = 0
        while let wheel = fling.step(dt: 1.0 / 60) {
            travel += wheel.dy
            _ = rig.surface.dragWheel(wheel, at: rig.thumb, rows: &rows)
        }
        await rig.settle()
        let flingRows = Int((travel / rig.surface.cellSize.height).rounded(.towardZero))
        #expect(flingRows > 3)
        #expect(rig.text == String(repeating: "\u{1b}OA", count: 3 + flingRows))
        // The next drag starts from a whole row: one row of finger, one key.
        rig.sent = Data()
        rig.pan(rows: 1, rows: &rows)
        await rig.settle()
        #expect(rig.text == "\u{1b}OA")
    }

    /// A tap is still the app's click where it asked for the mouse.
    @Test func aTapStillClicksInAnAppThatAskedForTheMouse() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed(Self.programs[0].modes)
        rig.sent = Data()
        #expect(rig.surface.click(at: CGPoint(x: rig.surface.gridPadding.x + 0.5 * rig.surface.cellSize.width,
                                              y: rig.surface.gridPadding.y + 0.5 * rig.surface.cellSize.height)))
        await rig.settle()
        #expect(rig.text.contains("\u{1b}[<0;1;1M"))
    }

    @Test func theRule() {
        #expect(TerminalPanRoute.route(alternateScreen: false, appReportsMouse: false) == .localScrollback)
        #expect(TerminalPanRoute.route(alternateScreen: false, appReportsMouse: true) == .localScrollback)
        #expect(TerminalPanRoute.route(alternateScreen: false, appReportsMouse: false, foregroundProgram: "less") == .localScrollback)
        #expect(TerminalPanRoute.route(alternateScreen: true, appReportsMouse: true) == .wheelReports)
        #expect(TerminalPanRoute.route(alternateScreen: true, appReportsMouse: true, foregroundProgram: "less") == .wheelReports)
        #expect(TerminalPanRoute.route(alternateScreen: true, appReportsMouse: false) == .none)
        #expect(TerminalPanRoute.route(alternateScreen: true, appReportsMouse: false, foregroundProgram: "claude") == .none)
        #expect(TerminalPanRoute.route(alternateScreen: true, appReportsMouse: false, foregroundProgram: "less") == .cursorKeys)
        #expect(TerminalPanRoute.route(alternateScreen: true, appReportsMouse: false, foregroundProgram: "/usr/bin/less") == .cursorKeys)
        #expect(TerminalPanRoute.route(alternateScreen: true, appReportsMouse: false, foregroundProgram: "-vim") == .cursorKeys)
    }

    @Test func wholeRows() {
        var rows = TerminalAlternateScroll.Rows()
        let slack = TerminalAlternateScroll.Rows.slack
        #expect(rows.take(6, rowHeight: 10) == nil)
        #expect(rows.take(6, rowHeight: 10) == (1 + slack) * 10)
        #expect(rows.take(-3, rowHeight: 10) == nil)
        #expect(rows.take(25, rowHeight: 10) == (2 + slack) * 10)
        #expect(rows.take(-31, rowHeight: 10) == (-2 - slack) * 10)
        rows.began()
        #expect(rows.take(9, rowHeight: 10) == nil)
        #expect(rows.take(5, rowHeight: 0) == nil)
    }
}
#endif
