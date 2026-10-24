import AppKit
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// Cmd-hover and Cmd-click on terminal links, on a real Ghostty surface driven by real
/// `NSEvent`s through the view's own mouse and key handlers: a URL with Command pressed over a
/// still pointer (focused or not), Shift-Command, a program that reads the mouse (Claude Code,
/// Codex), an OSC 8 hyperlink, and a URL the program broke onto two rows itself.
@MainActor @Suite(.serialized) struct TerminalCmdClickLinkTests {
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

        /// Mouse presses (SGR) the program read since `start`.
        @MainActor func presses(since start: Int) async throws -> Int {
            try await Task.sleep(for: .milliseconds(300))
            let text = io.writes.dropFirst(start).map { String(decoding: $0, as: UTF8.self) }.joined()
            // Left-button presses only: motion reports (any-motion tracking) end in `M` too.
        return text.matches(of: try Regex(#"\x1b\[<0;\d+;\d+M"#)).count
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
        #expect(try await h.presses(since: start) == 0, "the program saw the Cmd-click")

        let plain = h.io.writes.count
        try await h.hover(4, 4, [])
        h.session.clickLinkForTesting(column: 4, row: 4, flags: [])
        #expect(try await h.presses(since: plain) == 1, "a plain click no longer reaches the program")
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
}
