#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12: "this terminal projection nigh unusable due to me scroll
/// and thumb land on subagent depiction"; then, of less, man and vim: "But
/// can't we do something here?". A drag over the terminal is a scroll in
/// the form the app asked for (``TerminalPanRoute``): never a keystroke
/// Claude Code reads as history or its agent list, and still a pager's
/// application cursor keys. These feed the modes
/// each program sets on start, captured from its PTY (Claude Code 2.1.322 with
/// and without `CLAUDE_CODE_DISABLE_MOUSE`, Codex, less/vim-style full-screen
/// apps, a plain shell), into a real Ghostty mirror surface, then drag ten rows
/// through the same path a finger takes, and count what reaches the remote.
@MainActor
@Suite(.serialized) struct TerminalPanRouteTests {
    struct Program: CustomStringConvertible, Sendable {
        let name: String
        let modes: String
        let route: TerminalPanRoute
        /// The drag sends application-mode arrows (a pager).
        var pagerArrows = false
        var description: String { name }
    }

    nonisolated static let programs: [Program] = [
        // Claude Code's full-screen renderer: alt screen, any-motion SGR mouse.
        Program(name: "claude-code", modes: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?2031h",
                route: .wheelReports),
        // Claude Code with mouse capture off: alt screen, no mouse reporting.
        // Ghostty's alternate scroll made each row of drag an arrow key here:
        // up walked the prompt history, down went into the agent list.
        Program(name: "claude-code-no-mouse", modes: "\u{1b}[?1049h\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?2031h", route: .cursorKeys,
                pagerArrows: false),
        // Codex: alt screen, any-motion SGR mouse, alternate scroll off.
        Program(name: "codex", modes: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1006h\u{1b}[?1007l\u{1b}[?2004h",
                route: .wheelReports),
        // less / man / vim without `mouse=a`: alt screen, application cursor
        // keys (their keypad mode); up and down move the page.
        Program(name: "less", modes: "\u{1b}[?1049h\u{1b}[?1h\u{1b}=", route: .cursorKeys, pagerArrows: true),
        // A plain shell: the primary screen, the phone's own scrollback.
        Program(name: "shell", modes: "\u{1b}[?2004h", route: .localScrollback),
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

        /// A slow ten-row drag down (toward older content) with the finger on
        /// the bottom row, where Claude Code draws its agent list: the moves a
        /// pan reports, through ``TerminalTUIScroll`` as the controller sends them.
        func pan(rows: Int = 10) {
            let row = surface.cellSize.height
            let thumb = CGPoint(x: surface.gridPadding.x + 4.5 * surface.cellSize.width,
                                y: surface.gridPadding.y + (Double(max(1, surface.grid.rows)) - 0.5) * row)
            var scroll = TerminalTUIScroll()
            scroll.began()
            let steps = rows * 4
            for step in 1...steps {
                let wheel = scroll.moved(translationY: CGFloat(step) * row / 4, velocityY: 150)
                if let wheel { surface.scrollWheel(at: thumb, deltaY: wheel.dy, momentum: wheel.momentum) }
            }
        }

        /// Normal-mode arrows: what walked Claude Code's history and agent list.
        var arrowKeys: Int {
            let text = String(decoding: sent, as: UTF8.self)
            return ["\u{1b}[A", "\u{1b}[B"].reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
        }

        /// Application-mode arrows: a pager's scroll.
        var pagerArrows: Int {
            let text = String(decoding: sent, as: UTF8.self)
            return ["\u{1b}OA", "\u{1b}OB"].reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
        }

        var wheelReports: Int {
            String(decoding: sent, as: UTF8.self).components(separatedBy: "\u{1b}[<6").count - 1
        }
    }

    @Test(arguments: programs)
    func aDragIsNeverAKeystroke(program: Program) async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed(program.modes + "\u{1b}[H\u{1b}[2Jtranscript\r\n")
        #expect(rig.surface.panRoute == program.route)
        rig.sent = Data()
        let start = ContinuousClock.now
        rig.pan()
        let encode = ContinuousClock.now - start
        await rig.settle()
        print("pan-route program=\(program.name) route=\(program.route) bytes=\(rig.sent.count) arrows=\(rig.arrowKeys) pagerArrows=\(rig.pagerArrows) wheelReports=\(rig.wheelReports) encode=\(encode)")
        #expect(rig.arrowKeys == 0)
        switch program.route {
        case .wheelReports:
            // The app scrolls its own history: one report per row (a slow drag).
            #expect((9...10).contains(rig.wheelReports))
        case .cursorKeys where program.pagerArrows:
            // The pager moves one line per row of drag, like a Mac trackpad.
            #expect((9...10).contains(rig.pagerArrows))
            #expect(rig.sent.count == rig.pagerArrows * 3)
        case .cursorKeys, .localScrollback:
            #expect(rig.sent.isEmpty)
        }
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
        #expect(String(decoding: rig.sent, as: UTF8.self).contains("\u{1b}[<0;1;1M"))
    }

    @Test func theRule() {
        #expect(TerminalPanRoute.route(alternateScreen: false, appReportsMouse: false) == .localScrollback)
        #expect(TerminalPanRoute.route(alternateScreen: false, appReportsMouse: true) == .localScrollback)
        #expect(TerminalPanRoute.route(alternateScreen: true, appReportsMouse: true) == .wheelReports)
        #expect(TerminalPanRoute.route(alternateScreen: true, appReportsMouse: false) == .cursorKeys)
        #expect(TerminalPanRoute.scrollsPage(Data("\u{1b}OA\u{1b}OB\u{1b}OA".utf8)))
        #expect(!TerminalPanRoute.scrollsPage(Data()))
        #expect(!TerminalPanRoute.scrollsPage(Data("\u{1b}[A".utf8)))
        #expect(!TerminalPanRoute.scrollsPage(Data("\u{1b}OA\u{1b}[B".utf8)))
        #expect(!TerminalPanRoute.scrollsPage(Data("\u{1b}OC".utf8)))
        #expect(!TerminalPanRoute.scrollsPage(Data("\u{1b}OA\u{1b}".utf8)))
        #expect(TerminalPanRoute.isWheelKeys(Data("\u{1b}[A\u{1b}[B".utf8)))
        #expect(TerminalPanRoute.isWheelKeys(Data("\u{1b}OB".utf8)))
        // Terminal replies are not wheel keys (a cursor position report, a focus report).
        #expect(!TerminalPanRoute.isWheelKeys(Data("\u{1b}[1;1R".utf8)))
        #expect(!TerminalPanRoute.isWheelKeys(Data("\u{1b}[I".utf8)))
    }
}
#endif
