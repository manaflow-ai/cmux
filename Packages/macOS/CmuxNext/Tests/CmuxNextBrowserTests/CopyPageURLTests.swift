import AppKit
import Testing
@testable import CmuxNextBrowser

/// Copy Page URL (Cmd-Shift-C) writes the page's full URL, not the
/// omnibar's elided text. The pasteboard is a fake: fleet test steps run
/// with no pasteboard server.
@MainActor
struct CopyPageURLTests {
    final class FakePasteboard: PageURLPasteboard {
        var written: [URL] = []
        func writePageURL(_ url: URL) { written.append(url) }
    }

    @Test func copiesTheFullURL() async throws {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let chrome = BrowserChromeView(tab: tab)
        let pasteboard = FakePasteboard()
        #expect(!chrome.copyPageURL(to: pasteboard), "no page, nothing copied")
        #expect(pasteboard.written.isEmpty)
        tab.load(URL(string: "https://www.example.org/a/b?q=1#frag")!)
        for _ in 0..<20 { await Task.yield() }
        #expect(chrome.copyPageURL(to: pasteboard))
        #expect(pasteboard.written.map(\.absoluteString) == ["https://www.example.org/a/b?q=1#frag"])
    }

    /// The NSPasteboard writer puts the URL and its text on the board (where
    /// a pasteboard server exists; skipped on fleet steps without one).
    @Test func nsPasteboardWritesURLAndText() {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-copy-url-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.writePageURL(URL(string: "https://example.com/x")!)
        // Fleet steps have no pasteboard server: nothing to read back there.
        guard board.types != nil else { return }
        #expect(board.string(forType: .string) == "https://example.com/x")
        #expect(board.types?.contains(.URL) == true)
    }
}
