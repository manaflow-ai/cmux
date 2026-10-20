import AppKit
import Testing
@testable import CmuxNextTerminal

@Suite("Terminal pasteboard", .serialized)
@MainActor
struct TerminalPasteboardTests {
    @Test func carriageReturnsBecomeNewlinesBeforePaste() throws {
        let pasteboard = NSPasteboard(name: .init("com.cmuxterm.tests.terminal-pasteboard"))
        pasteboard.clearContents()
        defer { pasteboard.clearContents() }
        try #require(pasteboard.setString("first\rsecond\r\nthird", forType: .string))

        #expect(TerminalPasteboard.pasteText(from: pasteboard) == "first\nsecond\nthird")
    }
}
