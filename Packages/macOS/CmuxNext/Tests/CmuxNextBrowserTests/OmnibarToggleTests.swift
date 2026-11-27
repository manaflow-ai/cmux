import AppKit
@testable import CmuxNextBrowser
import Testing

/// Toggle Omnibar (`palette.browserToggleOmnibar`, `cmux browser
/// toggle-omnibar`): a browser tab's address bar row hides and shows again.
/// The page keeps the space; pane fullscreen still hides the row while the
/// person's choice is "shown".
@MainActor @Suite(.serialized) struct OmnibarToggleTests {
    static func chrome() -> BrowserChromeView { chromeAndPage().chrome }

    static func chromeAndPage() -> (chrome: BrowserChromeView, page: MockBrowserTab) {
        let engine = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: true)
        let page = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let chrome = BrowserChromeView(tab: page)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        chrome.layoutSubtreeIfNeeded()
        return (chrome, page)
    }

    @Test func toggleOmnibarHidesAndShowsTheToolbarRow() {
        let chrome = Self.chrome()
        #expect(!chrome.isOmnibarHidden)
        #expect(chrome.toolbarHeight.constant > 0)

        chrome.toggleOmnibar()
        #expect(chrome.isOmnibarHidden)
        #expect(chrome.isToolbarHidden)
        #expect(chrome.toolbarHeight.constant == 0, "the toolbar row still takes space")

        chrome.toggleOmnibar()
        #expect(!chrome.isOmnibarHidden)
        #expect(!chrome.isToolbarHidden)
        #expect(chrome.toolbarHeight.constant > 0)
    }

    @Test func aHiddenOmnibarStaysHiddenWhenThePageRendersAgain() async {
        let (chrome, page) = Self.chromeAndPage()
        chrome.toggleOmnibar()
        // A page update renders the chrome again on a later main-actor turn (`ObservationLoop`).
        page.load(URL(string: "https://example.com/next")!)
        for _ in 0..<10 { await Task.yield() }
        #expect(chrome.isToolbarHidden, "a page update showed the hidden address bar again")
    }
}
