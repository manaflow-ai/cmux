import AppKit
import Testing
@testable import CmuxNextBrowser

/// Copy Page URL (Cmd-Shift-C) writes the page's full URL, not the
/// omnibar's elided text.
@MainActor
struct CopyPageURLTests {
    @Test func copiesTheFullURL() async throws {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let chrome = BrowserChromeView(tab: tab)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux-copy-url-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(!chrome.copyPageURL(to: pasteboard), "no page, nothing copied")
        tab.load(URL(string: "https://www.example.org/a/b?q=1#frag")!)
        for _ in 0..<20 { await Task.yield() }
        #expect(chrome.copyPageURL(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "https://www.example.org/a/b?q=1#frag")
    }
}
