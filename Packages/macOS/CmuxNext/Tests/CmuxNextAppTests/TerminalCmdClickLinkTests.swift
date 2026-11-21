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

    /// Records link opens. The link check answers off the main thread as the app's file check
    /// does; by default every text it is asked about is a link.
    final class Opens: TerminalSessionDelegate {
        var texts: [String] = []
        let accepts: @Sendable (String) -> Bool
        init(accepts: @escaping @Sendable (String) -> Bool = { _ in true }) { self.accepts = accepts }
        func terminalSession(_ session: TerminalSession, openLink text: String) -> Bool {
            texts.append(text)
            return true
        }

        func terminalSessionLinkCheck(_ session: TerminalSession) -> TerminalLinkCheck? {
            let accepts = accepts
            return { text, _ in accepts(text) }
        }
    }

    final class Harness {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let opens: Opens
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        @MainActor init(focused: Bool = true, accepts: @escaping @Sendable (String) -> Bool = { _ in true }) throws {
            opens = Opens(accepts: accepts)
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
        // Ghostty finds nothing on the second row: cmux underlines both rows.
        #expect(h.session.model.hoveredLink == nil)
        #expect(h.session.linkPointerStateForTesting.underlinedRows == [1, 2])
        h.session.clickLinkForTesting(column: 4, row: 2)
        try await h.hover(10, 1)
        // Ghostty underlines the first row's piece itself: cmux underlines only the second row.
        #expect(h.session.model.hoveredLink == first)
        #expect(h.session.linkPointerStateForTesting.underlinedRows == [2])
        h.session.clickLinkForTesting(column: 10, row: 1)
        #expect(h.opens.texts == [url, url])
    }

    /// The second row of a broken URL is underlined even when its text also appears in the first
    /// row's piece, which Ghostty underlines itself (only the pointer's row is Ghostty's).
    @Test func aShortTailOfABrokenURLIsStillUnderlined() async throws {
        let h = try Harness()
        defer { h.close() }
        let width = h.columns - 2
        let first = "https://example.com/v1/" + String(repeating: "a", count: width - 23)
        let url = first + "1"
        try await h.output(Self.mouseModes + "\u{1b}[2;3H\(first)\u{1b}[3;3H1", showing: "v1")
        try await h.hover(10, 1)
        try await h.hover(11, 1)
        #expect(h.session.model.hoveredLink == first)
        #expect(h.session.linkPointerStateForTesting.wrapped == url)
        #expect(h.session.linkPointerStateForTesting.underlinedRows == [2])
    }

    /// A URL the terminal wrapped, or an OSC 8 link on several rows, Ghostty finds and underlines on
    /// every row itself: cmux adds no line of its own (two lines under each row before), and the click
    /// is Ghostty's, which opens the whole link.
    @Test func aLinkGhosttyUnderlinesGetsNoSecondUnderline() async throws {
        let h = try Harness()
        defer { h.close() }
        let url = "https://example.com/terminal-wrapped/" + String(repeating: "part-", count: h.columns / 5 + 2) + "end"
        try await h.output(Self.mouseModes + "\u{1b}[2;1H\u{1b}]8;;\(url)\u{1b}\\\(url)\u{1b}]8;;\u{1b}\\", showing: "end")
        try await h.hover(4, 2)
        #expect(h.session.model.hoveredLink == url)
        #expect(h.session.linkPointerStateForTesting.wrapped == nil)
        #expect(h.session.linkPointerStateForTesting.underlinedRows.isEmpty)
        h.session.clickLinkForTesting(column: 4, row: 2)
        #expect(h.opens.texts == [url])
    }

    /// A bare file name (`index.js:57:1`) has no folder part, so Ghostty's path pattern misses it.
    /// One that names a file is underlined with the hand, and a Cmd-click opens it with its line,
    /// also in a program that reads the mouse, which never sees the click. One that names nothing
    /// stays plain text.
    @Test func aBareFileNameThatExistsIsALink() async throws {
        let h = try Harness(accepts: { $0 == "./index.js:57:1" })
        defer { h.close() }
        // The shell reports its folder (OSC 7), as cmux's shell integration does; a bare name is a
        // path in it.
        try await h.output("\u{1b}]7;file://localhost/tmp\u{7}" + Self.mouseModes
            + "\u{1b}[2;3HAnswer: index.js:57:1.\u{1b}[3;3HNot here: missing.py:3", showing: "missing")
        try await h.wait { h.session.surfaceView.surface.map(ghostty_surface_mouse_captured) == true && h.session.model.workingDirectory != nil }
        try await h.hover(14, 1)
        try await h.hover(15, 1)
        #expect(h.session.model.hoveredLink == nil, "Ghostty matched a bare file name")
        #expect(h.session.linkPointerStateForTesting.wrapped == "./index.js:57:1")
        #expect(h.session.linkPointerStateForTesting.underlinedRows == [1])
        #expect(h.session.linkPointerStateForTesting.pointingHand)
        let start = h.io.writes.count
        h.session.clickLinkForTesting(column: 15, row: 1)
        #expect(h.opens.texts == ["./index.js:57:1"])
        let click = try await h.clicks(since: start)
        #expect(click.presses == 0 && click.releases == 0, "the program saw the Cmd-click: \(click)")

        try await h.hover(16, 2)
        try await h.hover(17, 2)
        #expect(h.session.linkPointerStateForTesting.wrapped == nil)
        h.session.clickLinkForTesting(column: 17, row: 2)
        #expect(h.opens.texts == ["./index.js:57:1"])
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
        // A table's column border is not the row's frame: the next row's first word stays out.
        let table = ["│ docs │ https://example.com/a │ ok │", "│ more │ text                  │    │"]
        #expect(TerminalWrappedLink.find(rows: table, firstRow: 0, columns: 37, column: 12, row: 0) == nil)
        // A VS16 emoji takes two cells, so the URL after it still reaches the edge.
        let emoji = ["⚠️ https://example.com/aaaaaaaa", "bbb/c"]
        #expect(TerminalWrappedLink.find(rows: emoji, firstRow: 0, columns: 31, column: 1, row: 1)?.text
            == "https://example.com/aaaaaaaabbb/c")
    }

    @Test func aBareFileNameIsReadAsAPathInTheTerminalsFolder() {
        let row = "  see index.js:57:1. or (main.c:3), README.md, app.py:12 and src/x.ts v1.2 e.g. https://a.io"
        func word(at needle: String, _ offset: Int = 1) -> String? {
            guard let range = row.range(of: needle) else { return nil }
            let column = row.distance(from: row.startIndex, to: range.lowerBound) + offset
            return TerminalWrappedLink.pathWord(in: row, columns: 120, column: column, row: 4)?.text
        }
        #expect(word(at: "index.js") == "./index.js:57:1")
        #expect(word(at: "main.c") == "./main.c:3")
        #expect(word(at: "README") == "./README.md")
        #expect(word(at: "app.py") == "./app.py:12")
        // A folder part, a version number and a scheme are Ghostty's, or no file name at all.
        #expect(word(at: "src/x.ts") == nil)
        #expect(word(at: "src/x.ts", 5) == nil)
        #expect(word(at: "v1.2") == nil)
        #expect(word(at: "https") == nil)
        let segment = TerminalWrappedLink.pathWord(in: row, columns: 120, column: 7, row: 4)?.segments.first
        #expect(segment == TerminalWrappedLink.Segment(row: 4, start: 6, end: 18, text: "index.js:57:1"))
    }
}
