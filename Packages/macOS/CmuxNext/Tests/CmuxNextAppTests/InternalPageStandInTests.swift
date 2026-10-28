import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextPages
@testable import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing
import WebKit

/// The cold-open stand-in in a page tab (feature `pageStandIn`): the tab's first build
/// shows it in the open's turn when the feature gave it a title, never under a discarded tab's picture,
/// and a pane swaps to it at once instead of holding the old content until the page's first frame
/// (Chrome shows a new tab's base background before the renderer's first frame,
/// content/browser/renderer_host/render_widget_host_view_mac.mm).
@MainActor @Suite(.serialized) struct InternalPageStandInTests {
    /// A page web view that loads nothing (its first paint never comes here).
    static func page() -> PageWebView {
        let configuration = WKWebViewConfiguration()
        return PageWebView(descriptor: PageDescriptor(id: "test.stand-in", resource: "stand-in", processGroup: .solo, namespaces: []),
                           configuration: configuration, inputReadiness: PageInputReadiness(configuration: configuration),
                           routes: [], route: nil, options: .standard, surface: nil, dynamicResources: nil, pooled: false,
                           load: false, chromium: nil, deadlines: .testing())
    }

    /// A 2x2 picture, as a discarded tab's last frame.
    static func picture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    /// A real pane in a window, as ``TabSwitchNoBlankFrameTests`` drives it.
    final class Pane {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let pane = PaneContentView.testing(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A")]),
                                           reveal: LaunchReveal(deadline: .zero))

        init() {
            window.isReleasedWhenClosed = false
            pane.barOrder = .aboveToolbar
            pane.frame = window.contentLayoutRect
            window.contentView = pane
            window.orderFrontRegardless()
        }

        func select(_ view: NSView) {
            pane.show(view)
            pane.layoutSubtreeIfNeeded()
        }

        /// The tab views the pane draws now.
        var shown: [NSView] {
            pane.contentHost.subviews.filter { !$0.isHidden && $0.alphaValue > 0 }
        }

        func tearDown() {
            window.orderOut(nil)
            window.close()
        }
    }

    @Test func aColdPageTabShowsItsStandInRightAfterItsBuild() {
        let page = Self.page()
        let view = InternalPageView(key: "local-page:settings:a", page: .settings, content: page, standInTitle: "Settings")
        #expect(view.isBuilt)
        #expect(page.showsStandIn, "the build did not show the stand-in in the open's turn")
        #expect(page.standIn?.title.string == "Settings")
        #expect(!view.awaitsFirstPaint, "the stand-in is the tab's first frame")
    }

    @Test func noTitleWhichIsTheFeatureOffShowsNoStandIn() {
        let page = Self.page()
        let view = InternalPageView(key: "local-page:settings:b", page: .settings, content: page, standInTitle: nil)
        #expect(view.isBuilt)
        #expect(!page.showsStandIn, "a stand-in showed with the feature off")
        #expect(view.awaitsFirstPaint, "with the feature off, the page waits for its first frame as before")
    }

    @Test func aRebuiltTabUnderItsPictureShowsNoStandIn() throws {
        let page = Self.page()
        let image = try Self.picture()
        let view = InternalPageView(key: "local-page:settings:c", page: .settings) {
            InternalPageView.Parts(content: page, standInTitle: "Settings") { view in
                view.rebuilt(under: image) { _ in }
            }
        }
        view.build()
        #expect(view.picture != nil, "the rebuilt tab lost its picture")
        #expect(!page.showsStandIn, "the stand-in covered the discarded tab's last picture")
    }

    @Test func aPaneSwapsToAPageShowingItsStandInInOneFrame() {
        let pane = Pane()
        defer { pane.tearDown() }
        let terminal = NSView()
        pane.select(terminal)
        let view = InternalPageView(key: "local-page:settings:d", page: .settings, content: Self.page(), standInTitle: "Settings")
        #expect(!PanePaintHold.holds(view, replacing: terminal), "a page showing its stand-in was held behind the old content")
        pane.select(view)
        #expect(view.alphaValue == 1, "the page with its stand-in stayed invisible")
        #expect(pane.shown.map(ObjectIdentifier.init) == [ObjectIdentifier(view)], "the old content stayed over the stand-in")
    }

    @Test func withTheFeatureOffAPaneStillHoldsTheOldContentUntilThePagePaints() {
        let pane = Pane()
        defer { pane.tearDown() }
        let terminal = NSView()
        pane.select(terminal)
        let view = InternalPageView(key: "local-page:settings:e", page: .settings, content: Self.page(), standInTitle: nil)
        #expect(PanePaintHold.holds(view, replacing: terminal))
        pane.select(view)
        #expect(view.alphaValue == 0, "the unpainted page showed blank with no stand-in")
        #expect(pane.shown.contains { $0 === terminal }, "the old content left before the page painted")
    }
}
