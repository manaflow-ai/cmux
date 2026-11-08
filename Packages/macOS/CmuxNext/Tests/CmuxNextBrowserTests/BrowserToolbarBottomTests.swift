import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// `browser.toolbarPosition` bottom (user, 2026-10-20: "move my OmniBar tabs to the bottom side"):
/// the toolbar rows sit under the page, the band for the pane's tab strip sits between the page and
/// the rows, and the omnibar's popups and the page's bars open away from the window's bottom edge.
/// Rects are in window coordinates (y up).
@MainActor @Suite(.serialized, .closesItsWindows) struct BrowserToolbarBottomTests {
    struct Chrome {
        let window: NSWindow
        let chrome: BrowserChromeView
        let page: WebKitTab

        init(position: ToolbarPosition) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            chrome = BrowserChromeView(tab: page)
            chrome.frame = window.contentLayoutRect
            window.contentView = chrome
            window.orderFrontRegardless()
            chrome.toolbarPosition = position
            chrome.layoutSubtreeIfNeeded()
        }

        func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

        func tearDown() {
            chrome.closePopupPanels()
            window.orderOut(nil)
            window.close()
            page.close()
        }
    }

    @Test func theToolbarSitsUnderThePage() {
        let view = Chrome(position: .bottom)
        defer { view.tearDown() }
        let toolbar = view.rect(view.chrome.toolbar), page = view.rect(view.chrome.contentContainer), all = view.rect(view.chrome)
        #expect(toolbar.height > 0)
        #expect(toolbar.minY == all.minY, "the toolbar row is the chrome's bottom row")
        #expect(page.maxY == all.maxY, "the page starts at the chrome's top")
        #expect(page.minY >= toolbar.maxY, "the page ends where the toolbar rows begin")
        #expect(view.chrome.toolbar.toolbarOpensUpward)
    }

    @Test func movingTheToolbarBackToTheTopRestoresTheRows() {
        let view = Chrome(position: .bottom)
        defer { view.tearDown() }
        view.chrome.toolbarPosition = .top
        view.chrome.layoutSubtreeIfNeeded()
        let toolbar = view.rect(view.chrome.toolbar), page = view.rect(view.chrome.contentContainer), all = view.rect(view.chrome)
        #expect(toolbar.maxY == all.maxY)
        #expect(page.minY == all.minY)
        #expect(!view.chrome.toolbar.toolbarOpensUpward)
    }

    /// The pane's tab strip band (`tabs.barOrder`) sits between the page and the toolbar rows.
    @Test func theTabStripBandSitsBetweenThePageAndTheToolbar() {
        let view = Chrome(position: .bottom)
        defer { view.tearDown() }
        view.chrome.setPaneHeaderBandHeight(30)
        view.chrome.layoutSubtreeIfNeeded()
        let band = view.chrome.convert(view.chrome.paneHeaderBandRect, to: nil)
        let toolbar = view.rect(view.chrome.toolbar), page = view.rect(view.chrome.contentContainer)
        #expect(band.height == 30)
        #expect(band.minY >= toolbar.maxY && band.maxY <= page.minY + 0.5, "page, band, toolbar from the top")
    }

    @Test func theFindPillSitsAtThePagesBottom() {
        let view = Chrome(position: .bottom)
        defer { view.tearDown() }
        view.chrome.showFindBar()
        view.chrome.layoutSubtreeIfNeeded()
        let find = view.rect(view.chrome.findBar), page = view.rect(view.chrome.contentContainer)
        #expect(find.minY == page.minY + FindPillMetrics.inset, "by the toolbar, not across the page from it")
    }

    /// The toolbar page opens its suggestion list above the bar (`omnibar.upward`, which the
    /// dropdown panel follows), and the bar keeps the row's gap from the row's bottom edge.
    @Test func suggestionsOpenAboveTheBar() throws {
        let view = Chrome(position: .bottom)
        defer { view.tearDown() }
        let state = view.chrome.addressBar.wireState()
        #expect((state["omnibar"] as? [String: Any])?["upward"] as? Bool == true)
        let metrics = try #require(state["metrics"] as? [String: Any])
        let barTop = try #require(metrics["barTop"] as? CGFloat)
        let scale = view.window.backingScaleFactor
        let row = view.chrome.addressBar.bounds.height
        #expect(abs(row - barTop - ToolbarRowMetrics.barHeight - ToolbarRowMetrics.barTop(scale: scale)) <= 0.5,
                "the bar sits the top row's distance above the row's bottom")
    }

    @Test func suggestionsStillOpenUnderATopBar() throws {
        let view = Chrome(position: .top)
        defer { view.tearDown() }
        let state = view.chrome.addressBar.wireState()
        #expect((state["omnibar"] as? [String: Any])?["upward"] as? Bool == false)
        let metrics = try #require(state["metrics"] as? [String: Any])
        #expect(metrics["barTop"] as? CGFloat == ToolbarRowMetrics.barTop(scale: view.window.backingScaleFactor))
    }
}
