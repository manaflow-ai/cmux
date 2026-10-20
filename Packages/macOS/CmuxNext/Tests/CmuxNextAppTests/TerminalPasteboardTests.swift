import AppKit
import Testing
@testable import CmuxNextTerminal

@Suite("Terminal pasteboard", .serialized)
@MainActor
struct TerminalPasteboardTests {
    @Test func carriageReturnsBecomeNewlinesBeforePaste() throws {
        // A uniquely named board: a fixed name is shared with every other test process on the
        // machine, and one that clears it between our clearContents and setString makes the
        // write fail.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try #require(pasteboard.setString("first\rsecond\r\nthird", forType: .string))

        #expect(TerminalPasteboard.pasteText(from: pasteboard) == "first\nsecond\nthird")
    }
}
