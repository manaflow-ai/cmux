import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// User, 2026-11-10: "for cmux-next browser tabs by default we shouldn't show the loading bar
/// under the omnibar area (but user can turn it on)". With `browser.showLoadingBar` unset, a
/// loading page draws no progress line under the toolbar; the reload button still turns into
/// Stop while the page loads, and Stop still stops it.
@MainActor @Suite(.serialized) struct LoadingBarSettingTests {
    @Test func aLoadingPageDrawsNoProgressLineByDefault() async {
        let chrome = NewTabQuietLoadTests.chrome(loading: "https://example.com/", design: DesignSettings())
        await NewTabQuietLoadTests.rendered()
        #expect(NewTabQuietLoadTests.progressBarOpacity(in: chrome) == 0, "no line under the omnibar by default")
        #expect(chrome.reloadButton.accessibilityLabel() == Strings.stop, "Stop still shows while the page loads")
    }

    @Test func stopStillStopsTheLoadWithTheLineHidden() async {
        let engine = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: false)
        let page = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let chrome = BrowserChromeView(tab: page, design: DesignSettings())
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        chrome.layoutSubtreeIfNeeded()
        #expect(page.state.isLoading)
        chrome.reloadButton.performClick(nil)
        await NewTabQuietLoadTests.rendered()
        #expect(!page.state.isLoading, "Stop ended the load")
        #expect(chrome.reloadButton.accessibilityLabel() == Strings.reload)
        #expect(NewTabQuietLoadTests.progressBarOpacity(in: chrome) == 0)
    }

    /// Settings > Browser > Show Loading Bar on: the line shows while the page loads, and turning
    /// it off mid-load hides it without a reload.
    @Test func turningTheSettingOnShowsTheLineLive() async {
        let design = DesignSettings()
        let chrome = NewTabQuietLoadTests.chrome(loading: "https://example.com/", design: design)
        #expect(NewTabQuietLoadTests.progressBarOpacity(in: chrome) == 0)
        design.browserShowsLoadingBar = true
        await NewTabQuietLoadTests.rendered()
        #expect(NewTabQuietLoadTests.progressBarOpacity(in: chrome) == 1, "on: the line shows under the omnibar")
        design.browserShowsLoadingBar = false
        await NewTabQuietLoadTests.rendered()
        #expect(NewTabQuietLoadTests.progressBarOpacity(in: chrome) == 0, "off again: it hides mid-load")
        #expect(chrome.reloadButton.accessibilityLabel() == Strings.stop)
    }
}
