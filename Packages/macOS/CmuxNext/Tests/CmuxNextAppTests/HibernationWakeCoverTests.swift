import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Foundation
import Testing

/// A woken tab must look instant (Chrome's Memory Saver reloads on show; cmux keeps the last frame).
/// A hibernated tab showed its picture only until its page was recreated: the live page then took
/// the pane at once and showed the theme color (no document painted yet) until it painted, a blank
/// frame between the picture and the page on every wake. The picture now stays over the page until
/// the page's own first contentful paint. Real WebKit pages, under critical memory pressure.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HibernationWakeCoverTests {
    /// A page whose first paint comes 1.5 s after it loads, as a heavy page's does.
    private static let slowPaint = """
        <script>const until = Date.now() + 1500; while (Date.now() < until) {}</script><p>painted</p>
        """

    @Test func theWokenPageKeepsItsPictureUntilItPaints() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        // The cap never runs out here: only the page's paint removes the picture.
        rig.hibernation.standInClock = ManualClock()
        let picture = try #require(Self.picture())
        rig.hibernation.capture = { _ in picture }
        let key = try await rig.hide(rig.page("slow", body: Self.slowPaint))
        try await rig.until("the page hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        try #require(rig.isHibernated(key))

        rig.window.contentView = rig.services.cache.browsers[key]?.tab.contentView
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the page was recreated") { !rig.isHibernated(key) }
        let page = try #require(rig.services.cache.browsers[key]?.tab as? WebKitTab)
        rig.window.contentView = page.contentView
        // The picture decodes off the main thread; the page paints 1.5 s after it loads.
        try await rig.until("the recreated page shows the tab's picture") { Self.cover(over: page) != nil }

        try await rig.until("the page painted and its picture went") { Self.cover(over: page) == nil }
        #expect(Self.cover(over: page) == nil)
    }

    /// A page that paints later than the cap shows itself loading rather than a frozen picture.
    @Test func thePictureGoesAtTheCapWhenThePageHasNotPainted() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let clock = ManualClock()
        rig.hibernation.standInClock = clock
        let picture = try #require(Self.picture())
        rig.hibernation.capture = { _ in picture }
        let never = "<script>const until = Date.now() + 8000; while (Date.now() < until) {}</script><p>late</p>"
        let key = try await rig.hide(rig.page("late", body: never))
        try await rig.until("the page hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        try #require(rig.isHibernated(key))
        rig.window.contentView = rig.services.cache.browsers[key]?.tab.contentView
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the page was recreated") { !rig.isHibernated(key) }
        let page = try #require(rig.services.cache.browsers[key]?.tab as? WebKitTab)
        rig.window.contentView = page.contentView
        try await rig.until("the recreated page shows the tab's picture") { Self.cover(over: page) != nil }
        try await clock.waitForSleeper()
        clock.advance(by: BrowserHibernation.standInCap)
        try await rig.until("the picture went at the cap") { Self.cover(over: page) == nil }
    }

    /// An image view over the whole page, above the web view.
    private static func cover(over page: WebKitTab) -> NSImageView? {
        guard let index = page.contentView.subviews.firstIndex(where: { $0 === page.webView }) else { return nil }
        return page.contentView.subviews[(index + 1)...].compactMap { $0 as? NSImageView }.first { !$0.isHidden && $0.image != nil }
    }

    private static func picture() -> CGImage? {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return context?.makeImage()
    }
}
