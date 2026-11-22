import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// R109: the browser opens an empty band under its toolbar rows for the
/// pane's tab strip; the page starts below it and the header includes it.
@MainActor @Suite struct BrowserHeaderBandTests {
    @Test func theBandSitsBetweenTheToolbarAndThePage() {
        let chrome = BrowserChromeView(tab: MockBrowserEngine().makeMockTab(BrowserTabConfiguration()))
        chrome.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        chrome.layoutSubtreeIfNeeded()
        let header = chrome.paneHeaderHeight
        #expect(chrome.paneHeaderBandRect.height == 0)
        chrome.setPaneHeaderBandHeight(30)
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.paneHeaderHeight == header + 30)
        let band = chrome.paneHeaderBandRect
        #expect(band.height == 30 && band.width == 700)
        let top = chrome.isFlipped ? band.minY : chrome.bounds.height - band.maxY
        #expect(abs(top - header) < 0.5)
        chrome.setPaneHeaderBandHeight(0)
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.paneHeaderHeight == header)
    }

    @Test func leavingTheSuperviewReleasesTheBandFirst() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let chrome = BrowserChromeView(tab: MockBrowserEngine().makeMockTab(BrowserTabConfiguration()))
        parent.addSubview(chrome)
        var released = 0
        chrome.onPaneHeaderBandRelease = { released += 1 }
        chrome.removeFromSuperview()
        #expect(released == 1)
    }
}
