import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// cmux#57419: a woken tab showed its last snapshot over the pane while its page loaded, then the live page at its
/// first paint. The snapshot was taken at another pane size, display or pixel budget (a hidden Chromium page's was the
/// 640 px hover thumbnail), so the loading page looked blurry and at the wrong size until it painted. A woken tab now
/// does what Chrome does with a discarded tab it reloads: the pane shows the page itself, its background until it
/// paints, never a picture over it. The snapshot stays for previews. Real WebKit pages, under critical memory pressure.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .closesItsWindows) struct HibernationWakeCoverTests {
    /// A page whose first paint comes 1.5 s after it loads, as a heavy page's does: it is still loading at the swap.
    private static let slowPaint = """
        <script>const until = Date.now() + 1500; while (Date.now() < until) {}</script><p>painted</p>
        """

    @Test func aSleepingTabAndItsLoadingWokenPageShowNoPictureOverThePage() async throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        let picture = try #require(Self.picture())
        rig.hibernation.capture = { _ in picture }
        let key = try await rig.hide(rig.page("swap", body: Self.slowPaint))
        try await rig.until("the page hibernated") { rig.isHibernated(key) || rig.exemption(key) != nil }
        let asleep = try #require(rig.services.cache.browsers[key]?.tab as? HibernatedBrowserTab)
        rig.window.contentView = asleep.contentView
        #expect(asleep.snapshotImage != nil, "the snapshot is kept for previews")
        #expect(Self.pictures(in: asleep.contentView).isEmpty, "the sleeping tab's pane shows its snapshot")

        var atSwap: [NSView]?
        let previous = rig.services.cache.onBrowserReady
        rig.services.cache.onBrowserReady = { [weak cache = rig.services.cache, weak window = rig.window] ready in
            previous?(ready)
            guard ready == key, atSwap == nil, let page = cache?.browsers[ready]?.tab as? WebKitTab else { return }
            window?.contentView = page.contentView
            atSwap = Self.pictures(in: page.contentView, skipping: page.webView)
        }
        rig.services.cache.present(key, by: rig.pane, presence: .visible)
        try await rig.until("the page was recreated") { atSwap != nil }
        #expect(atSwap?.isEmpty == true, "the loading page has a picture over it: \(atSwap ?? [])")
    }

    /// Views drawing a picture in `view`'s tree (an image view with an image, or a layer whose contents are an image),
    /// outside `skipping` (the page's own web view draws itself).
    private static func pictures(in view: NSView, skipping: NSView? = nil) -> [NSView] {
        view.subviews.flatMap { sub -> [NSView] in
            guard sub !== skipping, !sub.isHidden else { return [] }
            let draws = (sub as? NSImageView)?.image != nil || (sub.layer?.contents).map { CFGetTypeID($0 as CFTypeRef) == CGImage.typeID } == true
            return (draws ? [sub] : []) + pictures(in: sub, skipping: skipping)
        }
    }

    private static func picture() -> CGImage? {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return context?.makeImage()
    }
}
