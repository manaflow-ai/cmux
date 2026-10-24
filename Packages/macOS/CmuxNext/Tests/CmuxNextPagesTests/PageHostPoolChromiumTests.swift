import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing
import WebKit

/// The page host pool's spare is a parked WebKit view (Settings, History, Cloud), and a claim takes
/// it only for a page that shows in WebKit. With `browser.defaultEngine` on `chromium` (the
/// default) every pooled page shows in Chromium, yet the pool built its spare after launch anyway:
/// a parked page and its WebKit web content process, held for the whole session, that no claim
/// could take (perf-lead.md F3: cmux's own pages cost nothing while nobody sees them).
@MainActor @Suite(.serialized) struct PageHostPoolChromiumTests {
    private func pool(_ hosting: FakeChromiumHosting, window: NSWindow) -> PageHostPool {
        // The build deadline never fires: each test drives the pool's events itself.
        let pool = PageHostPool(clock: PageTestClock.never, activity: { 0 }, isTrackingMenu: { false },
                                chromiumHosting: { hosting })
        pool.start(isMainWindow: { $0 === window }, fallback: { _ in nil })
        return pool
    }

    /// A ready WebKit spare parked in the pool's window, as a build leaves it (nothing loaded, so
    /// the test needs no bundled page).
    @discardableResult
    private func parkSpare(in pool: PageHostPool, hosting: FakeChromiumHosting) throws -> PageWebView {
        let configuration = WKWebViewConfiguration()
        let host = PageWebView(descriptor: .settings, configuration: configuration,
                               inputReadiness: PageInputReadiness(configuration: configuration), routes: [], route: nil,
                               options: .standard, surface: nil, dynamicResources: nil, pooled: true, load: false,
                               chromium: hosting)
        pool.park(host, in: try #require(pool.target?.contentView))
        pool.spare = host
        pool.spareReady = true
        return host
    }

    /// The person chose WebKit, a spare warmed, then they switched to Chromium. The claim that
    /// dropped the spare left the pool likely, and nothing else checked the engine: the next key
    /// window, release or build parked a new WebKit spare no claim could take.
    @Test func aSwitchToChromiumDropsTheSpareAndNoEventWarmsAnother() throws {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        let pool = pool(hosting, window: window)
        defer { pool.dropSpare() }
        pool.noteLikely()
        try parkSpare(in: pool, hosting: hosting)
        #expect(pool.hostCount == 1)

        hosting.preference = .chromium
        #expect(pool.claim(.settings, routes: [], window: window) == nil)
        #expect(pool.hostCount == 0)
        #expect(!pool.shouldBuild)

        let other = PageHostPoolLaunchWindowTests.shownWindow()
        defer { other.close() }
        pool.follow(other)
        pool.follow(window)
        pool.noteLikely()
        #expect(!pool.shouldBuild, "a key window armed a WebKit spare while every pooled page shows in Chromium")
        #expect(!pool.timer.isScheduled)
        #expect(pool.hostCount == 0)
    }

    /// A host claimed while WebKit was chosen and released after a switch to Chromium closes; it
    /// does not become the spare.
    @Test func aHostReleasedAfterASwitchToChromiumIsNotKeptAsTheSpare() throws {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        let pool = pool(hosting, window: window)
        defer { pool.dropSpare() }
        pool.noteLikely()
        try parkSpare(in: pool, hosting: hosting)
        let claimed = try #require(pool.claim(.settings, routes: [], window: window))

        hosting.preference = .chromium
        pool.release(claimed)
        #expect(pool.spare == nil, "a released host became a WebKit spare no claim can take")
        #expect(pool.hostCount == 0)
        #expect(!pool.shouldBuild)
    }

    /// The engine change itself drops the spare, with no claim of Settings, History or Cloud.
    @Test func anEngineChangeDropsTheSpareAtOnce() throws {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        let pool = pool(hosting, window: window)
        defer { pool.dropSpare() }
        pool.noteLikely()
        try parkSpare(in: pool, hosting: hosting)

        hosting.preference = .chromium
        pool.engineMayHaveChanged()
        #expect(pool.hostCount == 0)
        #expect(!pool.isLikely)
        #expect(!pool.shouldBuild)
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
