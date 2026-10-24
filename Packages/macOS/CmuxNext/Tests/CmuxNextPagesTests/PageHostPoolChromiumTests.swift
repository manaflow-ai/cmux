import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing

/// The page host pool's spare is a parked WebKit view (Settings, History, Cloud), and a claim takes
/// it only for a page that shows in WebKit. With `browser.defaultEngine` on `chromium` (the
/// default) every pooled page shows in Chromium, yet the pool built its spare after launch anyway:
/// a parked page and its WebKit web content process, held for the whole session, that no claim
/// could take (perf-lead.md F3: cmux's own pages cost nothing while nobody sees them).
@MainActor @Suite(.serialized) struct PageHostPoolChromiumTests {
    private func pool(_ hosting: FakeChromiumHosting, window: NSWindow) -> PageHostPool {
        let pool = PageHostPool(activity: { 0 }, isTrackingMenu: { false }, chromiumHosting: { hosting })
        pool.start(isMainWindow: { $0 === window }, fallback: { _ in nil })
        return pool
    }

    @Test func aPoolWhosePagesShowInChromiumWarmsNoWebKitSpare() {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        let pool = pool(hosting, window: window)
        defer { pool.dropSpare() }

        pool.noteLikely()
        #expect(!pool.isLikely, "the pool warms a WebKit spare that no Chromium page can claim")
        #expect(!pool.shouldBuild)
        // A Chromium page opens fresh and warms nothing either.
        #expect(pool.claim(.settings, routes: [], window: window) == nil)
        #expect(!pool.shouldBuild)
        #expect(pool.hostCount == 0)
    }

    /// The person chose WebKit: pooled pages show there, and the spare still warms after launch.
    @Test func aPoolWhosePagesShowInWebKitStillWarms() {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        let pool = pool(hosting, window: window)
        defer { pool.dropSpare() }

        pool.noteLikely()
        #expect(pool.isLikely)
        #expect(pool.shouldBuild)
    }
}
