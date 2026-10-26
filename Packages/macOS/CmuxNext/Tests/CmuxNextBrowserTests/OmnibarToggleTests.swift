import AppKit
@testable import CmuxNextBrowser
import Testing
import CmuxNextWakeups

/// Toggle Omnibar (`palette.browserToggleOmnibar`, `cmux browser
/// toggle-omnibar`): a browser tab's address bar row hides and shows again.
/// The page keeps the space; pane fullscreen still hides the row while the
/// person's choice is "shown".
@MainActor @Suite(.serialized) struct OmnibarToggleTests {
    static func chrome() -> BrowserChromeView { chromeAndPage().chrome }

    static func chromeAndPage() -> (chrome: BrowserChromeView, page: MockBrowserTab) {
        let engine = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: true)
        let page = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let chrome = BrowserChromeView(tab: page, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        chrome.layoutSubtreeIfNeeded()
        return (chrome, page)
    }

    @Test func toggleOmnibarHidesAndShowsTheToolbarRow() {
        let chrome = Self.chrome()
        #expect(!chrome.isOmnibarHidden)
        #expect(chrome.toolbarRowHeight > 0)

        chrome.toggleOmnibar()
        #expect(chrome.isOmnibarHidden)
        #expect(chrome.isToolbarHidden)
        #expect(chrome.toolbarRowHeight == 0, "the toolbar row still takes space")

        chrome.toggleOmnibar()
        #expect(!chrome.isOmnibarHidden)
        #expect(!chrome.isToolbarHidden)
        #expect(chrome.toolbarRowHeight > 0)
    }

    @Test func aHiddenOmnibarStaysHiddenWhenThePageRendersAgain() async {
        let (chrome, page) = Self.chromeAndPage()
        chrome.toggleOmnibar()
        // A page update renders the chrome again on its scheduler's next run loop turn (`ObservationLoop`).
        page.load(URL(string: "https://example.com/next")!)
        await NewTabQuietLoadTests.rendered()
        #expect(chrome.isToolbarHidden, "a page update showed the hidden address bar again")
    }
}
