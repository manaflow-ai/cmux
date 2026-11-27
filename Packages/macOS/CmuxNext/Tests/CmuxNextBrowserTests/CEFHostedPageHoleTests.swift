import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Testing

/// cmux-ad m37, Lawrence 2026-11-05 ("chrome bg is black on cmd shift l aka new tab"): a Chromium tab before its first
/// real page (the New Tab page, a blank page) is a hole in its page window, so the window's backdrop shows there as in a
/// cmux New Tab (`CEFTab.applyOcclusion`). Chromium's own page under that hole is an opaque theme color. With layer hosting
/// on (#36311), the page's pixels reach the window through `CEFHostedPageView`, and the page window's holes did not apply
/// to them: the whole page area showed Chromium's opaque near-black instead of the backdrop. A hosted page now shows no
/// pixels where its page window has a hole.
@MainActor
@Suite(.closesItsWindows) struct CEFHostedPageHoleTests {
    let fake = CEFLayerHostingTests.FakeFork()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

    func makeHosting() -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { $0() },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 0 }, refreshIntervals: { [1.0 / 120] })
        hosting.view = view
        return hosting
    }

    /// A hosted page that shows nothing: its root layer has a mask that covers no point.
    static func showsNoPixels(_ page: CEFHostedPageView) -> Bool {
        guard let mask = page.layer?.mask else { return false }
        if let shape = mask as? CAShapeLayer { return shape.path.map { $0.boundingBoxOfPath.isEmpty } ?? true }
        return mask.bounds.isEmpty
    }

    @Test func aNewTabPageIsAHoleInItsHostedPageToo() throws {
        let hosting = makeHosting()
        // The New Tab page: the whole web contents are a hole, set before the page is hosted.
        hosting.pageHole = .whole
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        let page = try #require(hosting.page, "SETUP: the page is not hosted")
        #expect(Self.showsNoPixels(page), "a hosted New Tab page shows Chromium's opaque page color over the window backdrop")
    }

    @Test func theHoleFollowsThePageAfterItIsHosted() throws {
        let hosting = makeHosting()
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        let page = try #require(hosting.page, "SETUP: the page is not hosted")
        #expect(page.layer?.mask == nil, "a real page shows all its pixels")
        hosting.pageHole = .whole
        #expect(Self.showsNoPixels(page), "a page that became a New Tab page still shows its pixels")
        // The first real page committed: the hole closes and the page shows again.
        hosting.pageHole = .none
        #expect(page.layer?.mask == nil, "a real page after a New Tab page stays hidden")
    }

    /// A side panel open on a New Tab page: only the web contents are a hole; the panel's part of the page shows.
    @Test func aPartialHoleCutsOnlyItsRect() throws {
        let hosting = makeHosting()
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        let page = try #require(hosting.page, "SETUP: the page is not hosted")
        let contents = CGRect(x: 0, y: 0, width: 300, height: 300)
        hosting.pageHole = .rect(contents)
        let mask = try #require(page.layer?.mask as? CAShapeLayer, "a partial hole has no mask")
        #expect(mask.fillRule == .evenOdd)
        let path = try #require(mask.path)
        #expect(!path.contains(CGPoint(x: 150, y: 150), using: .evenOdd), "the web contents' hole shows the page")
        #expect(path.contains(CGPoint(x: 350, y: 150), using: .evenOdd), "the side panel's part of the page is cut")
    }
}
