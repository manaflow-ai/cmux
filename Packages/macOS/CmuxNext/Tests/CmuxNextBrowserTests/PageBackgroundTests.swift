import AppKit
import Testing
import WebKit
@testable import CmuxNextBrowser

/// User feedback on nxdog9: a new or loading browser tab never flashes
/// white. Until its first page finishes, a WebKit tab draws no background
/// of its own, so the pane's theme color shows; after that the page (or
/// WebKit's white default for pages without a background) draws.
@MainActor @Suite struct PageBackgroundTests {
    private func makeTab(url: URL? = nil) -> WebKitTab {
        let engine = WebKitEngine(profileStore: WebKitProfileStore(factory: FakeDataStoreFactory()), applicationNameForUserAgent: nil)
        return engine.makeWebKitTab(BrowserTabConfiguration(initialURL: url))
    }

    private func drawsBackground(_ tab: WebKitTab) -> Bool? {
        tab.webView.value(forKey: "drawsBackground") as? Bool
    }

    @Test func aNewBlankTabDrawsNoBackgroundOfItsOwn() {
        let tab = makeTab()
        #expect(drawsBackground(tab) == false)
        tab.close()
    }

    @Test func theFirstFinishedPageDrawsNormally() async throws {
        let html = "<html><body>plain</body></html>"
        let url = try #require(URL(string: "data:text/html;charset=utf-8," + html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!))
        let tab = makeTab(url: url)
        #expect(drawsBackground(tab) == false, "no white while the page loads")
        for _ in 0..<400 where drawsBackground(tab) != true {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(drawsBackground(tab) == true)
        tab.close()
    }
}
