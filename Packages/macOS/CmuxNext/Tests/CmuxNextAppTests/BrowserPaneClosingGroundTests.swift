import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// CLOSE MOTION 2 case 3 (cmux-ad m48): the last tab of a pane is a page, and the close springs its neighbour over the
/// pane. The closing pane shows only its ground (`PaneHostView.showClosingGround`, read once from
/// `NSView.paneGroundColor`), and a page pane's ground was its chrome's, the window's own color: the page went in the
/// close's turn and the window background showed where it was. Its ground is the shown page's own background.
@MainActor @Suite(.serialized) struct BrowserPaneClosingGroundTests {
    struct Pane {
        let pane: PaneContentView
        let chrome: BrowserChromeView
        let page: WebKitTab

        init() {
            pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("browser"), title: "Page")]),
                                   reveal: LaunchReveal(deadline: .zero))
            pane.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
            chrome = BrowserChromeView(tab: page)
            pane.show(chrome)
            pane.layoutSubtreeIfNeeded()
        }

        func tearDown() {
            chrome.closePopupPanels()
            page.close()
        }
    }

    /// sRGB components of `color`, to compare colors made in different spaces.
    static func rgb(_ color: CGColor?) -> [CGFloat]? {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent].map { ($0 * 255).rounded() }
    }

    @Test func aPagePaneClosesOnThePagesOwnBackground() async throws {
        let pane = Pane()
        defer { pane.tearDown() }
        // The fixture page's yellow, read when it loads (`WebKitTab.samplePageBackdrop`).
        let webView = pane.page.webView
        webView.loadHTMLString("<html style=\"background: rgb(255, 255, 0)\"><body>page</body></html>",
                               baseURL: URL(string: "https://ground.example/"))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while Self.rgb(pane.pane.paneGroundColor) != [255, 255, 0, 255], clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Self.rgb(pane.pane.paneGroundColor) == [255, 255, 0, 255])
    }

    @Test func aPageWithNoBackgroundReadKeepsTheChromesGround() {
        let pane = Pane()
        defer { pane.tearDown() }
        #expect(pane.page.pageBackdropARGB == nil)
        #expect(Self.rgb(pane.pane.paneGroundColor) == Self.rgb(pane.chrome.layer?.backgroundColor))
    }
}
