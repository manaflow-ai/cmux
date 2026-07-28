import AppKit
import Testing

@testable import CmuxTerminal

@Suite("Rejected HTML pasteboard fallback", .serialized)
struct PasteboardRejectedHTMLFallbackTests {
    @Test("image with rejected HTML preserves advertised plain text")
    func imageWithRejectedHTMLPreservesPlainText() {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-rejected-html-\(UUID().uuidString)")
        )
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let depth = 1_024
        let rejectedHTML = String(repeating: "<div>", count: depth)
            + "rich"
            + String(repeating: "</div>", count: depth)
        pasteboard.declareTypes([.png, .html, .string], owner: nil)
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pasteboard.setString(rejectedHTML, forType: .html)
        pasteboard.setString("plain fallback", forType: .string)

        #expect(
            TerminalPasteboardService().stringContents(from: pasteboard)
                == "plain fallback"
        )
    }
}
