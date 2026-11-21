import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// One chrome per pane (#34062) with FRAME OWNER S3's key-resize hold: the hold's end reaches only the page the chrome
/// shows, so a page parked in the shared page area while a hold ran must not keep it. Else a Chromium page shown again
/// after the hold ended holds a stale size (clipped, the backdrop beside it) through later resizes.
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserChromePaneMotionParkTests {
    /// The hold each mock page was last given (a Chromium page keeps its size while it holds one).
    nonisolated(unsafe) static var holds: [ObjectIdentifier: PaneMotionHold] = [:]

    static func tab(_ host: String) -> MockBrowserTab {
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://\(host)/")))
        tab.load(URL(string: "https://\(host)/")!)
        return tab
    }

    @Test func aPageParkedDuringAKeyResizeHoldDoesNotKeepItAfterTheHoldEnds() {
        Self.holds = [:]
        let a = Self.tab("a.example"), b = Self.tab("b.example")
        let stateA = BrowserChromeTabState(), stateB = BrowserChromeTabState()
        let pane = BrowserPaneChrome()
        let chrome = pane.bind(a, state: stateA)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
        defer {
            window.close()
            pane.drop()
            a.close()
            b.close()
        }
        let pageA = ObjectIdentifier(a.contentView)
        chrome.followPaneMotion(PaneMotionHold(trailing: true, bottom: false), heldSize: nil)
        #expect(Self.holds[pageA] != nil, "the shown page holds through the key resize")
        pane.bind(b, state: stateB)  // a tab switch while the key is held: page a parks in the shared page area
        chrome.followPaneMotion(nil, heldSize: nil)  // the hold ends
        #expect(Self.holds[pageA] == nil, "the parked page kept the key-resize hold after it ended")
    }
}

extension MockPageView: BrowserPagePaneMotionHolding {
    var holdsPageInPaneMotion: Bool { true }

    func holdPage(for hold: PaneMotionHold?) {
        BrowserChromePaneMotionParkTests.holds[ObjectIdentifier(self)] = hold
    }
}
