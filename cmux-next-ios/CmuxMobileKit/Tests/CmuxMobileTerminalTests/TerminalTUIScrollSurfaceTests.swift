#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// T-SCROLL-12 through the real Ghostty surface in mirror mode: the phone's
/// wheel goes through Ghostty's own encoder, so the app gets what Ghostty
/// sends on a Mac trackpad: SGR wheel reports when it asked for the mouse
/// (DECSET 1000 + 1006), cursor keys on the alternate screen with alternate
/// scroll (DECSET 1007, Ghostty's default; `ESC O A`/`B` in application cursor
/// mode), and nothing with 1007 off. Ghostty decides by the terminal's modes,
/// never by which program runs (Leo: "we shouldn't be accounting for an
/// endless number of apps").
@MainActor
@Suite(.serialized) struct TerminalTUIScrollSurfaceTests {
    /// A mirror surface in a window, its output fed and its input collected.
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

        /// A wheel of `rows` rows at the middle of `cell` (column, row).
        func wheel(rows: Double, column: Int, row: Int) {
            let size = surface.cellSize
            let padding = surface.gridPadding
            let point = CGPoint(x: padding.x + (Double(column) + 0.5) * size.width, y: padding.y + (Double(row) + 0.5) * size.height)
            surface.scrollWheel(at: point, deltaY: rows * size.height, momentum: .none)
        }

        /// A tap at the middle of `cell` (column, row).
        @discardableResult
        func tap(column: Int, row: Int) -> Bool {
            let size = surface.cellSize
            let padding = surface.gridPadding
            return surface.click(at: CGPoint(x: padding.x + (Double(column) + 0.5) * size.width, y: padding.y + (Double(row) + 0.5) * size.height))
        }

        var text: String { String(decoding: sent, as: UTF8.self) }

        /// Lets bytes Ghostty wrote from its own thread reach `onInput` (a check
        /// that nothing was sent must not pass only because they were late).
        func settle() async {
            for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }
        }

        /// What the app was sent, once at least `expected`'s bytes have come. Ghostty
        /// can write from its own thread; those bytes reach `onInput` on a later turn of
        /// the main queue, not during the wheel or tap that caused them, so reading
        /// `text` at once found it empty (1 run in 16 of the full kit). The limit is a
        /// watchdog against a hang, not a time the bytes are expected to take.
        func text(awaiting expected: String) async -> String {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while sent.count < expected.utf8.count, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return text
        }
    }

    /// TUI capability check F1: a tap in an app that asked for the mouse
    /// (vim `mouse=a`, htop's header, mc, tmux panes) is a left click at
    /// that cell, press then release, like a click in Ghostty on the Mac.
    @Test func aTapIsAClickWhenTheAppAskedForTheMouse() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        rig.sent = Data()
        #expect(rig.tap(column: 3, row: 5))
        let click = "\u{1b}[<0;4;6M\u{1b}[<0;4;6m"
        #expect(await rig.text(awaiting: click) == click)
    }

    @Test func aTapSendsNothingWithoutMouseReporting() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h")
        rig.sent = Data()
        #expect(!rig.tap(column: 3, row: 5))
        #expect(rig.sent.isEmpty)
    }

    @Test func aMouseReportingAppGetsSGRWheelReportsAtTheFinger() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        rig.sent = Data()
        rig.wheel(rows: 3, column: 3, row: 5)
        let up = String(repeating: "\u{1b}[<64;4;6M", count: 3)
        #expect(await rig.text(awaiting: up) == up)
        rig.sent = Data()
        rig.wheel(rows: -2, column: 0, row: 0)
        let down = String(repeating: "\u{1b}[<65;1;1M", count: 2)
        #expect(await rig.text(awaiting: down) == down)
    }

    @Test(arguments: ["1002", "1003"])
    func buttonAndAnyMotionTrackingGetWheelReportsToo(mode: String) async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?\(mode)h\u{1b}[?1006h")
        rig.sent = Data()
        rig.wheel(rows: 2, column: 3, row: 5)
        let wheel = String(repeating: "\u{1b}[<64;4;6M", count: 2)
        let text = await rig.text(awaiting: wheel)
        // Any-motion tracking may also report the pointer reaching the cell first.
        #expect(text.hasSuffix(wheel))
        #expect(text.components(separatedBy: "[<64;").count == 3)
        #expect(!text.contains("\u{1b}[A"))
    }

    /// TUI fast scroll, through Ghostty's own encoder: a slow drag of two
    /// rows is two wheel reports (line by line); a fast drag of two rows is
    /// more, like a Mac trackpad's accelerated deltas.
    @Test func aSlowDragIsOneReportPerRowAndAFastDragMore() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        rig.sent = Data()
        let row = rig.surface.cellSize.height
        let at = CGPoint(x: rig.surface.gridPadding.x + 3.5 * rig.surface.cellSize.width,
                         y: rig.surface.gridPadding.y + 5.5 * row)
        var scroll = TerminalTUIScroll()
        scroll.began()
        let slowWheel = scroll.moved(translationY: 2 * row, velocityY: 150)
        let slow = try #require(slowWheel)
        rig.surface.scrollWheel(at: at, deltaY: slow.dy, momentum: slow.momentum)
        let line = String(repeating: "\u{1b}[<64;4;6M", count: 2)
        #expect(await rig.text(awaiting: line) == line)
        rig.sent = Data()
        let fastWheel = scroll.moved(translationY: 4 * row, velocityY: 3000)
        let fast = try #require(fastWheel)
        rig.surface.scrollWheel(at: at, deltaY: fast.dy, momentum: fast.momentum)
        let accelerated = String(repeating: "\u{1b}[<64;4;6M", count: Int(2 * TerminalTUIScroll.maximumGain))
        #expect(await rig.text(awaiting: accelerated) == accelerated)
    }

    @Test func theAlternateScreenGetsArrowsByDefault() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h")
        rig.sent = Data()
        rig.wheel(rows: 2, column: 1, row: 1)
        #expect(await rig.text(awaiting: "\u{1b}[A\u{1b}[A") == "\u{1b}[A\u{1b}[A")
        rig.sent = Data()
        rig.wheel(rows: -1, column: 1, row: 1)
        #expect(await rig.text(awaiting: "\u{1b}[B") == "\u{1b}[B")
    }

    @Test func applicationCursorKeysSendSS3Arrows() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1h")
        rig.sent = Data()
        rig.wheel(rows: 1, column: 1, row: 1)
        #expect(await rig.text(awaiting: "\u{1b}OA") == "\u{1b}OA")
        rig.sent = Data()
        rig.wheel(rows: -2, column: 1, row: 1)
        #expect(await rig.text(awaiting: "\u{1b}OB\u{1b}OB") == "\u{1b}OB\u{1b}OB")
    }

    @Test func alternateScrollOffSendsNothing() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1007l")
        rig.sent = Data()
        rig.wheel(rows: 4, column: 1, row: 1)
        rig.wheel(rows: -4, column: 1, row: 1)
        await rig.settle()
        #expect(rig.sent.isEmpty)
    }

    /// Mouse reporting wins over alternate scroll: wheel reports, no arrows.
    @Test func mouseReportingWinsOverAlternateScroll() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1h\u{1b}[?1007h\u{1b}[?1000h\u{1b}[?1006h")
        rig.sent = Data()
        rig.wheel(rows: 2, column: 3, row: 5)
        let wheel = String(repeating: "\u{1b}[<64;4;6M", count: 2)
        #expect(await rig.text(awaiting: wheel) == wheel)
        await rig.settle()
        #expect(rig.text == wheel)
    }

    /// The modes Claude Code's full-screen renderer and Codex set on start
    /// (captured from their PTYs): any-motion SGR mouse, so a wheel is a
    /// wheel report at the finger and never an arrow, with 1007 on or off.
    @Test(arguments: [
        "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?2031h",
        "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1004h\u{1b}[?1006h\u{1b}[?1007l\u{1b}[?2004h",
    ])
    func claudeCodeAndCodexGetWheelReports(modes: String) async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed(modes)
        rig.sent = Data()
        rig.wheel(rows: 3, column: 4, row: 20)
        let up = String(repeating: "\u{1b}[<64;5;21M", count: 3)
        let text = await rig.text(awaiting: up)
        // Any-motion tracking may also report the pointer reaching the cell first.
        #expect(text.hasSuffix(up))
        #expect(!text.contains("\u{1b}[A") && !text.contains("\u{1b}OA"))
    }

    /// A full-screen program the phone has never heard of gets exactly what
    /// Ghostty sends for its modes: the same bytes for less, man, vim, nano,
    /// top, a remote pager over ssh, tmux, Claude Code without mouse capture
    /// and a made-up TUI. No program name is read or matched anywhere.
    struct Program: CustomStringConvertible, Sendable {
        let name: String
        let modes: String
        /// One row toward older content, then one toward newer.
        let up: String
        let down: String
        var description: String { name }
    }

    nonisolated static let csi = ("\u{1b}[A", "\u{1b}[B")
    nonisolated static let ss3 = ("\u{1b}OA", "\u{1b}OB")
    nonisolated static let programs: [Program] = [
        Program(name: "less", modes: "\u{1b}[?1049h\u{1b}[?1h\u{1b}=", up: ss3.0, down: ss3.1),
        Program(name: "man", modes: "\u{1b}[?1049h\u{1b}[?1h\u{1b}=", up: ss3.0, down: ss3.1),
        Program(name: "vim", modes: "\u{1b}[?1049h\u{1b}[?1h\u{1b}=\u{1b}[?2004h", up: ss3.0, down: ss3.1),
        Program(name: "nano", modes: "\u{1b}[?1049h\u{1b}[?1h\u{1b}=\u{1b}[?2004h", up: ss3.0, down: ss3.1),
        Program(name: "top", modes: "\u{1b}[?1049h\u{1b}[?25l", up: csi.0, down: csi.1),
        Program(name: "ssh", modes: "\u{1b}[?1049h\u{1b}[?1h\u{1b}=", up: ss3.0, down: ss3.1),
        Program(name: "tmux", modes: "\u{1b}[?1049h\u{1b}[?1h\u{1b}=\u{1b}[?25l\u{1b}[?1004h", up: ss3.0, down: ss3.1),
        Program(name: "claude-code-no-mouse", modes: "\u{1b}[?1049h\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?2031h", up: csi.0, down: csi.1),
        Program(name: "mycustomtui", modes: "\u{1b}[?1049h", up: csi.0, down: csi.1),
    ]

    @Test(arguments: programs)
    func anyProgramGetsGhosttysArrowsWithAlternateScrollOn(program: Program) async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed(program.modes + "\u{1b}[H\u{1b}[2J\(program.name)\r\n")
        rig.sent = Data()
        rig.wheel(rows: 3, column: 4, row: 20)
        let up = String(repeating: program.up, count: 3)
        #expect(await rig.text(awaiting: up) == up, "\(program.name)")
        rig.sent = Data()
        rig.wheel(rows: -2, column: 4, row: 20)
        let down = String(repeating: program.down, count: 2)
        #expect(await rig.text(awaiting: down) == down, "\(program.name)")
        // DECRST 1007: the same program, nothing.
        await rig.feed("\u{1b}[?1007l")
        rig.sent = Data()
        rig.wheel(rows: 3, column: 4, row: 20)
        await rig.settle()
        #expect(rig.sent.isEmpty, "\(program.name)")
    }

    /// A finger's slow ten-row drag, as the controller sends it (a wheel per
    /// quarter row through ``TerminalTUIScroll``), on the alternate screen
    /// without mouse reporting: Ghostty carries each part of a row, so the
    /// app gets one arrow per row and nothing else.
    @Test func aSlowDragIsOneArrowPerRow() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1h")
        rig.sent = Data()
        let row = rig.surface.cellSize.height
        let at = CGPoint(x: rig.surface.gridPadding.x + 4.5 * rig.surface.cellSize.width,
                         y: rig.surface.gridPadding.y + 20.5 * row)
        var scroll = TerminalTUIScroll()
        scroll.began()
        for step in 1...40 {
            if let wheel = scroll.moved(translationY: CGFloat(step) * row / 4, velocityY: 150) {
                rig.surface.scrollWheel(at: at, deltaY: wheel.dy, momentum: wheel.momentum)
            }
        }
        _ = await rig.text(awaiting: String(repeating: "\u{1b}OA", count: 9))
        await rig.settle()
        let arrows = rig.text.components(separatedBy: "\u{1b}OA").count - 1
        #expect((9...10).contains(arrows))
        #expect(rig.text == String(repeating: "\u{1b}OA", count: arrows))
    }

    /// The primary screen (a shell, Claude Code's inline frame): Ghostty
    /// scrolls its own viewport and the Mac gets nothing.
    @Test(arguments: ["\u{1b}[?2004h", "\u{1b}[?1004h\u{1b}[?2004h\u{1b}[?2031h\u{1b}[?25l"])
    func thePrimaryScreenSendsNothing(modes: String) async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed(modes + "$ \r\n")
        rig.sent = Data()
        rig.wheel(rows: 3, column: 1, row: 1)
        rig.wheel(rows: -3, column: 1, row: 1)
        await rig.settle()
        #expect(rig.sent.isEmpty)
    }

    @Test func lessThanARowOfArrowsWaitsForMore() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h")
        rig.sent = Data()
        rig.wheel(rows: 0.6, column: 1, row: 1)
        #expect(rig.sent.isEmpty)
        rig.wheel(rows: 0.6, column: 1, row: 1)
        #expect(await rig.text(awaiting: "\u{1b}[A") == "\u{1b}[A")
    }

    @Test func lessThanARowWaitsForMore() async throws {
        let rig = Rig()
        try #require(rig.surface.surface != nil)
        await rig.feed("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        rig.sent = Data()
        rig.wheel(rows: 0.6, column: 1, row: 1)
        #expect(rig.sent.isEmpty)
        rig.wheel(rows: 0.6, column: 1, row: 1)
        let one = "\u{1b}[<64;2;2M"
        #expect(await rig.text(awaiting: one) == one)
    }
}
#endif
