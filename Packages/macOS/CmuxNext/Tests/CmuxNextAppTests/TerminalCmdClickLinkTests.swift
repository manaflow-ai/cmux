import AppKit
@testable import CmuxNextApp
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing
import struct CmuxNextBrowser.TerminalLinkResolver
import enum CmuxNextBrowser.TerminalLinkTarget

/// Cmd-hover and Cmd-click on terminal links, on a real Ghostty surface driven by real
/// `NSEvent`s through the view's own mouse and key handlers: a URL with Command pressed over a
/// still pointer (focused or not), Shift-Command, a program that reads the mouse (Claude Code,
/// Codex), an OSC 8 hyperlink, and a URL the program broke onto two rows itself.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalCmdClickLinkTests {
    /// Mouse modes Codex 0.163 sets (alt screen, button and any-motion tracking in SGR).
    static let mouseModes = "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h"

    /// Records link opens; every link the filter asks about is one, answered off the main
    /// thread as the app's file check is.
    final class Opens: TerminalSessionDelegate {
        var texts: [String] = []
        func terminalSession(_ session: TerminalSession, openLink text: String) -> Bool {
            texts.append(text)
            return true
        }

        func terminalSessionLinkCheck(_ session: TerminalSession) -> TerminalLinkCheck? {
            { _, _ in true }
        }
    }

    final class Harness {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let opens = Opens()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        @MainActor init(focused: Bool = true) throws {
            _ = NSApplication.shared
            _ = GhosttyRuntime.shared
            session = TerminalSession(io: io)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            session.delegate = opens
            window.isReleasedWhenClosed = false
            window.contentView = session.view
            session.view.layoutSubtreeIfNeeded()
            window.makeFirstResponder(focused ? session.surfaceView : nil)
        }

        @MainActor func close() {
            io.finish()
            window.close()
        }

        @MainActor var columns: Int {
            guard let surface = session.surfaceView.surface else { return 0 }
            return Int(ghostty_surface_size(surface).columns)
        }

        /// Feeds `text` as program output and waits until the viewport shows `marker`.
        @MainActor func output(_ text: String, showing marker: String) async throws {
            io.send(.output(Data(text.utf8)))
            try await wait { self.session.surfaceView.viewportText()?.contains(marker) == true }
        }

        @MainActor func wait(_ done: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline, !done() {
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        @MainActor func hover(_ column: Int, _ row: Int, _ flags: NSEvent.ModifierFlags = .command) async throws {
            session.hoverLinkForTesting(column: column, row: row, flags: flags)
            // The link filter answers off the main thread, then the pointer goes to Ghostty again.
            try await Task.sleep(for: .milliseconds(150))
        }

        /// Left-button presses and releases (SGR) the program read since `start`; motion
        /// (any-motion tracking) and wheel reports do not count.
        @MainActor func clicks(since start: Int) async throws -> (presses: Int, releases: Int) {
            try await Task.sleep(for: .milliseconds(300))
            let text = io.writes.dropFirst(start).map { String(decoding: $0, as: UTF8.self) }.joined()
            var presses = 0, releases = 0
            for match in text.matches(of: try Regex(#"\x1b\[<(\d+);\d+;\d+([Mm])"#)) {
                guard let code = Int(match.output[1].substring ?? ""), code & (32 | 64) == 0, code & 3 == 0 else { continue }
                if match.output[2].substring == "M" { presses += 1 } else { releases += 1 }
            }
            return (presses, releases)
        }
    }

    @Test func commandPressedOverAStillPointerFindsAndOpensTheLink() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.output("https://example.com/still\r\n", showing: "still")
        try await h.hover(3, 0, [])
        h.session.modifiersChangedForTesting(.command)
        try await h.wait { h.session.model.hoveredLink != nil }
        #expect(h.session.model.hoveredLink == "https://example.com/still", "Command over a still pointer found no link")
        h.session.clickLinkForTesting(column: 3, row: 0)
        #expect(h.opens.texts == ["https://example.com/still"])
        h.session.modifiersChangedForTesting([])
        #expect(h.session.model.hoveredLink == nil, "releasing Command kept the link")
    }

    @Test func aTerminalWithoutFocusFindsTheLinkWhenCommandGoesDown() async throws {
        let h = try Harness(focused: false)
        defer { h.close() }
        try await h.output("https://example.com/unfocused\r\n", showing: "unfocused")
        try await h.hover(3, 0, [])
        h.session.modifiersChangedForTesting(.command)
        try await h.wait { h.session.model.hoveredLink != nil }
        #expect(h.session.model.hoveredLink == "https://example.com/unfocused", "an unfocused terminal ignored Command")
    }

    @Test func shiftCommandClickOpensTheLink() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.output("https://example.com/shift\r\n", showing: "shift")
        try await h.hover(3, 0, [.command, .shift])
        try await h.hover(4, 0, [.command, .shift])
        h.session.clickLinkForTesting(column: 4, row: 0, flags: [.command, .shift])
        #expect(h.opens.texts == ["https://example.com/shift"])
    }

    @Test func aProgramThatReadsTheMouseKeepsCmdClickLinksAndPlainClicks() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.output(Self.mouseModes + "\u{1b}[3;3HPlain: https://example.com/tui\u{1b}[5;3Hplain text", showing: "plain text")
        try await h.wait { h.session.surfaceView.surface.map(ghostty_surface_mouse_captured) == true }
        try await h.hover(12, 2)
        try await h.hover(13, 2)
        #expect(h.session.model.hoveredLink == "https://example.com/tui", "Cmd-hover found no link in a mouse-reading program")
        #expect(h.session.linkPointerStateForTesting.pointingHand)

        let start = h.io.writes.count
        h.session.clickLinkForTesting(column: 13, row: 2)
        #expect(h.opens.texts == ["https://example.com/tui"])
        let linkClick = try await h.clicks(since: start)
        #expect(linkClick.presses == 0 && linkClick.releases == 0, "the program saw the Cmd-click: \(linkClick)")

        let plain = h.io.writes.count
        try await h.hover(4, 4, [])
        h.session.clickLinkForTesting(column: 4, row: 4, flags: [])
        let plainClick = try await h.clicks(since: plain)
        #expect(plainClick.presses == 1 && plainClick.releases == 1, "a plain click no longer reaches the program whole: \(plainClick)")
    }

    /// A Cmd-press on plain text belongs to the program: a drag onto a link and the release
    /// there reach it too, so it never keeps a pressed button, and no link opens.
    @Test func aCmdPressOffALinkReachesTheProgramWholeEvenWhenReleasedOnALink() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.output(Self.mouseModes + "\u{1b}[3;3HPlain: https://example.com/tui\u{1b}[5;3Hplain text", showing: "plain text")
        try await h.wait { h.session.surfaceView.surface.map(ghostty_surface_mouse_captured) == true }
        try await h.hover(4, 4)
        let start = h.io.writes.count
        h.session.dragForTesting(from: (4, 4), to: (13, 2))
        let drag = try await h.clicks(since: start)
        #expect(drag.presses == 1 && drag.releases == 1, "the program lost half of a Cmd-drag: \(drag)")
        #expect(h.opens.texts.isEmpty, "a drag that began off a link opened one")
    }

    @Test func anOSC8HyperlinkOpensItsTargetInAMouseReadingProgram() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.output(Self.mouseModes + "\u{1b}[2;3H\u{1b}]8;;https://example.com/target\u{1b}\\open the docs\u{1b}]8;;\u{1b}\\",
                           showing: "open the docs")
        try await h.hover(5, 1)
        h.session.clickLinkForTesting(column: 5, row: 1)
        #expect(h.opens.texts == ["https://example.com/target"])
    }

    @Test func aURLTheProgramBrokeOntoTwoRowsOpensWholeFromEitherRow() async throws {
        let h = try Harness()
        defer { h.close() }
        let width = h.columns - 2
        let url = "https://example.com/wrapped/" + String(repeating: "segment-", count: width / 8 + 2) + "end"
        let first = String(url.prefix(width)), second = String(url.dropFirst(width))
        try await h.output(Self.mouseModes + "\u{1b}[2;3H\(first)\u{1b}[3;3H\(second)", showing: "end")
        try await h.hover(4, 2)
        #expect(h.session.linkPointerStateForTesting.wrapped == url)
        #expect(h.session.linkPointerStateForTesting.pointingHand)
        h.session.clickLinkForTesting(column: 4, row: 2)
        try await h.hover(10, 1)
        h.session.clickLinkForTesting(column: 10, row: 1)
        #expect(h.opens.texts == [url, url])
    }

    @Test func aPrintedPathKeepsItsLineAndColumn() {
        let code = TerminalLinkResolver().location("src/app.ts:3:5")
        #expect(code?.line == 3 && code?.column == 5)
        let note = TerminalLinkResolver().location("\"notes/todo.md:12\",")
        #expect(note?.line == 12 && note?.column == nil)
        #expect(TerminalLinkResolver().location("README.md") == nil)
        #expect(TerminalLinkResolver().location("localhost:3000/docs") == nil)
        #expect(TerminalLinkResolver().location("https://example.com:8080") == nil)
    }

    @Test func onlyAWordBrokenAtTheEdgeJoinsTheNextRow() {
        // 30 columns: the first row's URL fills the row.
        let wrapped = ["  https://example.com/aaaaaaaa", "  bbbb/c?d=1 and more"]
        #expect(TerminalWrappedLink.find(rows: wrapped, firstRow: 0, columns: 30, column: 3, row: 1)?.text
            == "https://example.com/aaaaaaaabbbb/c?d=1")
        #expect(TerminalWrappedLink.find(rows: wrapped, firstRow: 0, columns: 30, column: 3, row: 1)?.segments.count == 2)
        // The URL ends well before the edge: the next row's word is not part of it.
        let short = ["  see https://example.com/x", "  next"]
        #expect(TerminalWrappedLink.find(rows: short, firstRow: 0, columns: 40, column: 3, row: 1) == nil)
        #expect(TerminalWrappedLink.find(rows: short, firstRow: 0, columns: 40, column: 10, row: 0) == nil)
        // A frame border after the URL does not stop the join.
        let framed = ["│ https://example.com/aaaaaa │", "│ bbb.html                   │"]
        #expect(TerminalWrappedLink.find(rows: framed, firstRow: 0, columns: 30, column: 10, row: 0)?.text
            == "https://example.com/aaaaaabbb.html")
        // Two cells short of the edge: prose on the next row stays out; a URL's own continuation
        // (it carries `/`, `?`, `=`) joins, for a program that keeps a right margin.
        let prose = ["  see https://example.com/abcd", "  and more text"]
        #expect(TerminalWrappedLink.find(rows: prose, firstRow: 0, columns: 32, column: 10, row: 0) == nil)
        #expect(TerminalWrappedLink.find(rows: prose, firstRow: 0, columns: 32, column: 2, row: 1) == nil)
        let margin = ["  see https://example.com/abcd", "  efg/h?i=1"]
        #expect(TerminalWrappedLink.find(rows: margin, firstRow: 0, columns: 32, column: 3, row: 1)?.text
            == "https://example.com/abcdefg/h?i=1")
        // Ghostty's own link (rows the terminal wrapped) joins rows whatever their edges, and only
        // as far as that link goes.
        let soft = ["  1: https://example.com/abc-", "  def-ghi end. Line 2", "  next"]
        let joined = TerminalWrappedLink.find(rows: soft, firstRow: 0, columns: 40, column: 4, row: 1,
                                              hint: "https://example.com/abc-def-ghi")
        #expect(joined?.text == "https://example.com/abc-def-ghi")
        #expect(joined?.segments.map(\.row) == [0, 1])
        #expect(TerminalWrappedLink.find(rows: soft, firstRow: 0, columns: 40, column: 4, row: 1) == nil)
        // A table's column border is not the row's frame: the next row's first word stays out.
        let table = ["│ docs │ https://example.com/a │ ok │", "│ more │ text                  │    │"]
        #expect(TerminalWrappedLink.find(rows: table, firstRow: 0, columns: 37, column: 12, row: 0) == nil)
        // A VS16 emoji takes two cells, so the URL after it still reaches the edge.
        let emoji = ["⚠️ https://example.com/aaaaaaaa", "bbb/c"]
        #expect(TerminalWrappedLink.find(rows: emoji, firstRow: 0, columns: 31, column: 1, row: 1)?.text
            == "https://example.com/aaaaaaaabbb/c")
    }
}
