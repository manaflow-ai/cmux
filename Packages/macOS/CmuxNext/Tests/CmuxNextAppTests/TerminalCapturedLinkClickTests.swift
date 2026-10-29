import AppKit
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// u11857: Cmd-click on `perf-status.md` in a Claude Code reply opened Finder, not cmux's Markdown
/// page. Claude Code's TUI turns mouse reporting on, and while a program has the mouse Ghostty
/// looks for links only with Shift held, so the Cmd-click never reached cmux's link open: it went
/// to Claude Code as a plain click (mouse reports cannot carry Command), and Claude Code ran
/// `/usr/bin/open` itself. Drives a real Ghostty surface with Claude Code's mouse modes and an
/// OSC 8 link, then real `NSEvent`s: a Cmd-click on the link opens it through the delegate (the
/// app's link path) and sends the program no click; plain clicks and Cmd-clicks off the link stay
/// the program's.
@MainActor @Suite(.serialized) struct TerminalCapturedLinkClickTests {
    /// Button, drag and any-motion tracking in SGR, as Claude Code's fullscreen TUI sets them.
    static let mouseModes = "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h"
    static let fileURL = "file:///tmp/a610-plans/perf-status.md"
    /// `perf-status.md` on the first row, an OSC 8 link to ``fileURL``; then plain text.
    static let linkLine = "\u{1b}[H\u{1b}]8;;\(fileURL)\u{1b}\\perf-status.md\u{1b}]8;;\u{1b}\\ is the doc"

    /// Records the links the surface asks the app to open.
    final class Opens: TerminalSessionDelegate {
        var links: [String] = []
        func terminalSession(_ session: TerminalSession, openLink text: String) -> Bool {
            links.append(text)
            return true
        }
        func terminalSession(_ session: TerminalSession, open url: URL) -> Bool {
            links.append(url.absoluteString)
            return true
        }
        func terminalSessionDidRingBell(_ session: TerminalSession) {}
        func terminalSessionDidRequestClose(_ session: TerminalSession) {}
    }

    final class Harness {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let opens = Opens()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        @MainActor init() throws {
            _ = NSApplication.shared
            _ = GhosttyRuntime.shared
            session = TerminalSession(io: io)
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            session.delegate = opens
            window.isReleasedWhenClosed = false
            window.contentView = session.view
            session.view.layoutSubtreeIfNeeded()
        }

        @MainActor func close() {
            io.finish()
            window.close()
        }

        @MainActor var reporting: Bool {
            guard let surface = session.surfaceView.surface else { return false }
            return ghostty_surface_mouse_captured(surface)
        }

        /// Feeds program output and waits until `done` (bounded: 10 s).
        @MainActor func output(_ text: String, until done: @MainActor () -> Bool) async throws {
            io.send(.output(Data(text.utf8)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline, !done() {
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        /// The window point of the middle of cell (`column`, `row`), top-left origin cells.
        @MainActor func point(column: Int, row: Int) -> NSPoint {
            let view = session.surfaceView
            let cell = view.cellPointSize
            let local = NSPoint(x: (Double(column) + 0.5) * cell.width, y: view.bounds.height - (Double(row) + 0.5) * cell.height)
            return view.convert(local, to: nil)
        }

        @MainActor func event(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }

        /// A pointer move to `point`, then a click there, with `flags` held throughout.
        @MainActor func click(at point: NSPoint, flags: NSEvent.ModifierFlags) {
            let view = session.surfaceView
            view.mouseMoved(with: event(.mouseMoved, at: point, flags: flags))
            view.mouseDown(with: event(.leftMouseDown, at: point, flags: flags))
            view.mouseUp(with: event(.leftMouseUp, at: point, flags: flags))
        }

        /// The SGR press and release reports written since `start`, waiting briefly for Ghostty's
        /// IO thread (motion reports, button 32 and up, are left out).
        @MainActor func clicks(since start: Int) async throws -> [String] {
            var last = -1
            for _ in 0..<25 {
                try await Task.sleep(for: .milliseconds(40))
                let count = io.writes.count
                if count == last { break }
                last = count
            }
            let text = io.writes.dropFirst(start).map { String(decoding: $0, as: UTF8.self) }.joined()
            return text.matches(of: try Regex(#"\x1b\[<(\d+);\d+;\d+[Mm]"#)).compactMap { match in
                let report = String(text[match.range])
                let button = Int(report.dropFirst(3).prefix { $0.isNumber }) ?? 0
                return button < 32 ? report : nil
            }
        }

        @MainActor func ready() async throws {
            try await output(TerminalCapturedLinkClickTests.mouseModes + TerminalCapturedLinkClickTests.linkLine) { reporting }
            try #require(reporting, "the surface never turned mouse reporting on")
        }
    }

    @Test func commandClickOnALinkOpensItInCmuxAndSendsTheProgramNoClick() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.ready()
        let start = h.io.writes.count
        h.click(at: h.point(column: 4, row: 0), flags: .command)
        let clicks = try await h.clicks(since: start)
        #expect(h.opens.links == [Self.fileURL], "the Cmd-click did not open the link through cmux")
        #expect(clicks.isEmpty, "the program got the Cmd-click on a link: \(clicks)")
    }

    @Test func plainClickOnALinkStaysTheProgramsClick() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.ready()
        let start = h.io.writes.count
        h.click(at: h.point(column: 4, row: 0), flags: [])
        let clicks = try await h.clicks(since: start)
        #expect(h.opens.links.isEmpty, "a plain click opened the link in cmux")
        #expect(clicks.count == 2, "the program did not get the plain click's press and release: \(clicks)")
    }

    @Test func commandClickOffALinkStaysTheProgramsClick() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.ready()
        let start = h.io.writes.count
        h.click(at: h.point(column: 10, row: 4), flags: .command)
        let clicks = try await h.clicks(since: start)
        #expect(h.opens.links.isEmpty, "a Cmd-click off the link opened something")
        #expect(clicks.count == 2, "the program did not get the Cmd-click off the link: \(clicks)")
    }
}
