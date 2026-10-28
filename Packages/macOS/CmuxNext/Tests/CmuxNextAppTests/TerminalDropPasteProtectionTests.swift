import AppKit
@testable import CmuxNextTerminal
import CmuxNextDesign
import CmuxNextWakeups
import Foundation
import Testing

/// Text or a file dropped onto a terminal is a paste and gets paste protection (Ghostty 1.4.0,
/// 5580df602 "macos: apply paste protection to dragged text", and 5c9a3d8a9: a carriage return
/// counts as a line break). Before, a drop went to the shell through `ghostty_surface_text`, which
/// skips the "Paste into the terminal?" prompt that Cmd-V of the same text shows, so a dropped
/// line break ran the command at once. Real Ghostty surface, scripted PTY, no bracketed paste.
@MainActor @Suite(.serialized) struct TerminalDropPasteProtectionTests {
    static let dialog = "cmux.dialog.terminalClipboard"

    final class Harness {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)

        @MainActor init() throws {
            _ = NSApplication.shared
            GhosttyRuntime.startedForTests()
            session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            window.isReleasedWhenClosed = false
            window.contentView = session.view
            session.view.layoutSubtreeIfNeeded()
            window.makeFirstResponder(session.surfaceView)
        }

        @MainActor func close() {
            for record in CmuxDialogCenter.shared.records where record.spec.identifier == TerminalDropPasteProtectionTests.dialog {
                _ = CmuxDialogCenter.shared.dismiss(record.id)
            }
            io.finish()
            window.close()
        }

        /// What the terminal wrote to the PTY since write `start`.
        func written(since start: Int) -> String {
            io.writes.dropFirst(start).map { String(decoding: $0, as: UTF8.self) }.joined()
        }

        /// The open paste confirmation, if any.
        @MainActor var prompt: CmuxDialogCenter.Record? {
            CmuxDialogCenter.shared.records.last { $0.spec.identifier == TerminalDropPasteProtectionTests.dialog }
        }

        @MainActor func ready() async throws {
            io.send(.output(Data("$ ready".utf8)))
            try await wait { self.session.surfaceView.viewportText()?.contains("ready") == true }
        }

        @MainActor func wait(_ done: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline, !done() {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    @Test(arguments: ["echo drop-marker\nrm -rf ~/scratch\n", "echo drop-marker\r", "echo drop-marker\r\n"])
    func aDroppedLineBreakAsksBeforeTheShellGetsIt(_ text: String) async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.ready()
        let start = h.io.writes.count

        #expect(h.session.surfaceView.pasteDropped(text))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!h.written(since: start).contains("drop-marker"), "the drop reached the shell with no prompt")
        let prompt = try #require(h.prompt, "no paste confirmation")

        #expect(CmuxDialogCenter.shared.press(prompt.id, button: "allow"))
        try await h.wait { h.written(since: start).contains("drop-marker") }
        #expect(h.written(since: start).contains("drop-marker"), "Allow did not paste the drop")
    }

    @Test func aDeniedDropSendsNothing() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.ready()
        let start = h.io.writes.count

        #expect(h.session.surfaceView.pasteDropped("echo denied-marker\n"))
        let prompt = try #require(h.prompt, "no paste confirmation")
        #expect(CmuxDialogCenter.shared.press(prompt.id, button: "deny"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!h.written(since: start).contains("denied-marker"))
    }

    @Test func aDropOnOneLineGoesStraightIn() async throws {
        let h = try Harness()
        defer { h.close() }
        try await h.ready()
        let start = h.io.writes.count

        #expect(h.session.surfaceView.pasteDropped("/tmp/one\\ line.txt"))
        try await h.wait { h.written(since: start).contains("/tmp/one\\ line.txt") }
        #expect(h.written(since: start).contains("/tmp/one\\ line.txt"))
        #expect(h.prompt == nil, "a safe drop asked")
    }
}
