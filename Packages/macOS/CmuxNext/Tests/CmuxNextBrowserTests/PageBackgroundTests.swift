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

    /// Chromium: the theme color (CefBrowserSettings.background_color)
    /// stays through blank documents and ends at the first real commit.
    @Test func chromiumKeepsTheThemeColorUntilTheFirstRealPageCommits() {
        let runtime = CEFRuntime.shared
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: "bg"), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        tab.handle(.loadStart(browser: 1, url: "about:blank"))
        #expect(tab.usesThemeBackground)
        tab.handle(.loadStart(browser: 1, url: "https://a.example/"))
        #expect(!tab.usesThemeBackground)
    }

    @Test func blankURLs() {
        #expect(PageBackground.isBlank(nil))
        #expect(PageBackground.isBlank(URL(string: "about:blank")))
        #expect(!PageBackground.isBlank(URL(string: "https://example.com")))
    }
}
