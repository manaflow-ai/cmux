import AppKit
@testable import CmuxNextBrowser
import Testing
import CmuxNextWakeups

/// Toggle Omnibar (`palette.browserToggleOmnibar`, `cmux browser
/// toggle-omnibar`): a browser tab's address bar row hides and shows again.
/// The page keeps the space; pane fullscreen still hides the row while the
/// person's choice is "shown".
@MainActor @Suite(.serialized) struct OmnibarToggleTests {
    static func chrome(renderServer: Bool = false) -> BrowserChromeView { chromeAndPage(renderServer: renderServer).chrome }

    static func chromeAndPage(renderServer: Bool = false) -> (chrome: BrowserChromeView, page: MockBrowserTab) {
        let engine = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: true)
        let page = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let chrome = BrowserChromeView(tab: page, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil,
                                       rendersMotionOnServer: { renderServer })
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
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.toolbar.isHidden, "outside a window the row hides at once")
        #expect(chrome.contentContainer.frame.maxY == chrome.bounds.maxY, "the page did not take the row's room")

        chrome.toggleOmnibar()
        #expect(!chrome.isOmnibarHidden)
        #expect(!chrome.isToolbarHidden)
        #expect(chrome.toolbarRowHeight > 0)
    }

    /// `motion.renderServer` on: the hidden row keeps its height past its edge, so a hide moves it.
    @Test func onTheRenderServerTheHiddenRowParksPastItsEdge() {
        let chrome = Self.chrome(renderServer: true)
        let rowHeight = chrome.toolbar.frame.height
        chrome.toggleOmnibar()
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.toolbar.isHidden, "outside a window the row hides at once")
        #expect(chrome.toolbar.frame.height == rowHeight, "the hidden row resized instead of moving past its edge")
        #expect(chrome.toolbar.frame.minY == chrome.bounds.maxY, "y up: the hidden row parks above the top edge")
        #expect(chrome.contentContainer.frame.maxY == chrome.bounds.maxY, "the page did not take the row's room")
    }

    /// `motion.renderServer` off (the default): the hidden row takes no height, as before.
    @Test func offTheRenderServerTheHiddenRowCollapses() {
        let chrome = Self.chrome()
        chrome.toggleOmnibar()
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.toolbar.isHidden)
        #expect(chrome.toolbar.frame.height == 0, "the step path parked the row instead of collapsing it")
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
