import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing

/// The suggestion card draws on the window's overlay host in the `.pane`
/// layer (plans/cmux-next/overlay-host.md, R126: no panel of its own and no
/// zPosition), flush under the bar and clipped to the browser pane.
@MainActor
@Suite(.serialized) struct OmnibarOverlayTests {
    @Test func theCardIsAPaneOverlayUnderTheBarWithNoPanelOfItsOwn() async throws {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let store = InMemoryBrowserHistory()
        for _ in 0..<5 { store.recordVisit(url: URL(string: "https://github.com/")!, title: "GitHub", at: Date()) }
        let chrome = BrowserChromeView(tab: tab, suggestionEngine: OmniboxSuggestionEngine(history: store))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        defer {
            chrome.addressBar.dismissRows()
            window.orderOut(nil)
        }
        tab.load(URL(string: "https://example.org/start")!)
        let bar = chrome.addressBar
        await bar.suggestionEngine.historySettled()
        bar.debugType("git")
        for _ in 0..<50 { await Task.yield() }
        while let query = bar.controller.pendingQuery {
            await query.value
            if bar.controller.pendingQuery == query { break }
        }
        #expect(bar.isShowingSuggestions)
        #expect(bar.suggestionPanel.isVisible)

        let host = try #require(WindowOverlayHost.existingHost(for: window))
        let handle = try #require(bar.suggestionPanel.overlay)
        #expect(host.presentedHandles.contains { $0 === handle })
        #expect(host.layerIndex(of: handle) == 0, "the .pane layer")
        #expect((window.childWindows ?? []).allSatisfy { $0 === host.panel }, "no suggestion panel of its own")

        // Flush under the bar, as wide as the card top, inside the pane.
        let card = bar.suggestionPanel.cardView.convert(bar.suggestionPanel.cardView.bounds, to: nil)
        let barRect = bar.convert(bar.bounds, to: nil)
        #expect(card.maxY == barRect.minY)
        #expect(card.minX == barRect.minX - OmnibarStyle.cardSideOutset)
        #expect(card.width == barRect.width + 2 * OmnibarStyle.cardSideOutset)
        #expect(bar.suggestionPanel.rowViews.count == bar.state.popup.rows.count)

        // What debug.omnibar reports for the live proof agrees.
        let reported = try #require(bar.debugCard)
        #expect(reported.paneLayer && reported.isFlushUnderBar)
        #expect(reported.rowKinds.first == "history")

        bar.dismissRows()
        #expect(!host.presentedHandles.contains { $0 === handle })
        #expect(handle.isDismissed)
        #expect(bar.debugCard == nil)
    }

    /// The card follows the bar when the chrome lays out again while it is
    /// open: a window resize, or a toolbar render that lands after the rows
    /// (#17601, where the bar had moved 12 pt left and grown 32 pt by then).
    @Test func theCardFollowsTheBarWhenTheChromeLaysOutAgain() async throws {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let store = InMemoryBrowserHistory()
        for _ in 0..<5 { store.recordVisit(url: URL(string: "https://github.com/")!, title: "GitHub", at: Date()) }
        let chrome = BrowserChromeView(tab: tab, suggestionEngine: OmniboxSuggestionEngine(history: store))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        defer {
            chrome.addressBar.dismissRows()
            window.orderOut(nil)
        }
        let bar = chrome.addressBar
        await bar.suggestionEngine.historySettled()
        bar.debugType("git")
        while let query = bar.controller.pendingQuery {
            await query.value
            if bar.controller.pendingQuery == query { break }
        }
        #expect(bar.isShowingSuggestions)
        let before = bar.convert(bar.bounds, to: nil)

        window.setContentSize(NSSize(width: 1_200, height: 360))
        chrome.layoutSubtreeIfNeeded()

        let barRect = bar.convert(bar.bounds, to: nil)
        #expect(barRect != before, "the resize moved the bar")
        let card = bar.suggestionPanel.cardView.convert(bar.suggestionPanel.cardView.bounds, to: nil)
        #expect(card.maxY == barRect.minY)
        #expect(card.minX == barRect.minX - OmnibarStyle.cardSideOutset)
        #expect(card.width == barRect.width + 2 * OmnibarStyle.cardSideOutset)
        #expect(bar.debugCard?.isFlushUnderBar == true)
    }
}
