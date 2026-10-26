import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Edge containers batch 1 (Leo 2026-10-12, "the browser pane's rounding"): a browser pane drew
/// two boxes. The pane's tab strip and the browser toolbar floated above a second rounded,
/// outlined box that held only the page, so the page's top corners rounded under the toolbar.
/// Like a terminal pane, a browser pane has one rounded content area below its tab strip; the
/// toolbar sits inside it and the page is square and flush under the toolbar.
@MainActor @Suite(.serialized) struct BrowserPaneOneContainerTests {
    struct Pane {
        let window: NSWindow
        let pane: PaneContentView
        let chrome: BrowserChromeView
        let page: WebKitTab

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("browser"), title: "Example")]),
                                   reveal: LaunchReveal(deadline: .zero))
            pane.barOrder = .aboveToolbar
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
            page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            chrome = BrowserChromeView(tab: page)
            pane.show(chrome)
            // What the layout hands every pane: the density's pane corner radius.
            pane.setPaneContentCornerRadius(6)
            pane.layoutSubtreeIfNeeded()
        }

        func tearDown() {
            window.orderOut(nil)
            window.close()
            page.close()
        }
    }

    @Test func theRoundedAreaStartsUnderTheTabStripNotUnderTheToolbar() {
        let tab = Pane()
        defer { tab.tearDown() }
        let strip = tab.pane.stripView.isHidden ? 0 : tab.pane.stripView.frame.height
        #expect(tab.chrome.contentContainer.frame.height < tab.chrome.bounds.height, "the toolbar sits above the page")
        #expect(tab.pane.paneHeaderHeight == strip,
                "the pane's header is its tab strip alone: the border and corners take the toolbar in")
    }

    @Test func thePageIsNotASecondRoundedBox() {
        let tab = Pane()
        defer { tab.tearDown() }
        #expect(tab.chrome.contentContainer.layer?.cornerRadius == 0, "the page is square under the toolbar")
        #expect(tab.pane.contentHost.layer?.cornerRadius == 6, "the pane's content area is the one rounded container")
    }

    /// A Chromium page is a child window and masks itself to the rounded clips around it
    /// (`CEFClipShape`): the one clip is the pane's content area, toolbar included, so the page
    /// is cut only at the pane's bottom corners.
    @Test func aChildWindowPageIsClippedOnlyByThePanesRoundedArea() throws {
        let tab = Pane()
        defer { tab.tearDown() }
        let probe = NSView(frame: tab.chrome.contentContainer.bounds)
        tab.chrome.contentContainer.addSubview(probe)
        let windowSize = tab.window.frame.size
        let clips = CEFClipShape.clips(around: probe).filter { $0.rect.size != windowSize }
        let clip = try #require(clips.count == 1 ? clips.first : nil, "one rounded clip around the page")
        #expect(clip.radius == 6)
        #expect(clip.rect.height > probe.bounds.height + 1, "the clip takes the toolbar in, not just the page")
        let topCorners = CGRect(x: 0, y: probe.isFlipped ? 0 : probe.bounds.maxY - 6, width: probe.bounds.width, height: 6)
        let topCut = CEFClipShape.path(bounds: topCorners, clips: clips)
        #expect(topCut == nil, "the page's top corners are square under the toolbar")
    }
}
