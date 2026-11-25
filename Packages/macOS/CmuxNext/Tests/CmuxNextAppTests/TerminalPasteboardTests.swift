import Testing
@testable import CmuxNextTerminal

/// The paste decision runs on ``TerminalPasteboardContents`` so the suite needs no
/// pasteboard server: a fleet test step has none, and there `NSPasteboard.setString`
/// returns false on any board, named or not (steps 42a180113a99a967bff08749,
/// e6356e4309c2331b1ed759e3, 57c30db644554fff8bb90ea1).
@MainActor
@Suite("Terminal pasteboard")
struct TerminalPasteboardTests {
    @Test func carriageReturnsBecomeNewlinesBeforePaste() {
        let contents = TerminalPasteboardContents(string: "first\rsecond\r\nthird")

        #expect(TerminalPasteboard.pasteText(from: contents) == "first\nsecond\nthird")
    }
}
