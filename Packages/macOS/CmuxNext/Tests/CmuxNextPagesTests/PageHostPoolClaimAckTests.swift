import AppKit
import CmuxNextSettings
@testable import CmuxNextPages
import Foundation
import Testing

/// A Settings claim from the parked spare hands the claim's routes to the spare's document by
/// message (`cmux.page.claim`): the document keeps running, its reads go through the new routes, and
/// it shows no read-only banner. A document that does not acknowledge the claim is reloaded.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct PageHostPoolClaimAckTests {
    @Test func aClaimedSpareReadsThroughTheClaimWithNoNewDocument() async throws {
        let window = Self.window()
        defer { window.close() }
        let pool = Self.pool(window)
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release) }
        let spare = try #require(await Self.settledSpare(pool))
        // The off-window page can miss the 50 ms wall-clock budget under shared-WebKit load, and a
        // timeout reloads the document. A manual clock leaves the acknowledgement as the only way the
        // claim ends.
        spare.claimState.clock = ClaimTestClock()
        // A marker on the spare's document: a reload or a new load drops it.
        _ = try await spare.webKitView.callAsyncJavaScript("window.__claimProbe = 'spare'; return true;", contentWorld: .page)

        let provider = PageHostPoolSettingsClaimTests.RecordingProvider()
        let page = try #require(pool.claim(.settings, routes: [PageRoute(prefix: "cmux.settings.", provider: provider)],
                                           route: "#/settings/terminal", window: window, focus: false))
        #expect(page === spare)
        Self.show(page, in: window)

        #expect(await Self.readAndListened(provider) == true, "ops \(provider.ops), streams \(provider.streams)")
        #expect(await Self.banner(in: page, becomes: "none") == "none", "the claimed page shows no read-only banner")
        let probe = try await page.webKitView.callAsyncJavaScript("return window.__claimProbe ?? null;", contentWorld: .page) as? String
        #expect(probe == "spare", "the claim must not navigate: the spare's document serves the claim")
        let hash = try await page.webKitView.callAsyncJavaScript("return location.hash;", contentWorld: .page) as? String
        #expect(hash == "#/settings/terminal")
        let section = try await page.webKitView.callAsyncJavaScript(
            "return document.querySelector('[data-section-link][aria-current]')?.dataset.sectionLink ?? null;",
            contentWorld: .page) as? String
        #expect(section == "terminal", "the page shows the claim's route")
        #expect(page.lastClaim?.path == .acknowledged)
    }

    @Test func aSpareThatDoesNotAcknowledgeTheClaimIsReloaded() async throws {
        let window = Self.window()
        defer { window.close() }
        let pool = Self.pool(window)
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release) }
        let spare = try #require(await Self.settledSpare(pool))
        // The document drops every host message, so the claim is never acknowledged.
        _ = try await spare.webKitView.callAsyncJavaScript(
            "window.__claimProbe = 'spare'; window.__cmuxPageReceive = () => {}; return true;", contentWorld: .page)

        let provider = PageHostPoolSettingsClaimTests.RecordingProvider()
        let page = try #require(pool.claim(.settings, routes: [PageRoute(prefix: "cmux.settings.", provider: provider)],
                                           route: "#/settings/general", window: window, focus: false))
        Self.show(page, in: window)

        #expect(await Self.readAndListened(provider) == true, "ops \(provider.ops), streams \(provider.streams)")
        #expect(await Self.banner(in: page, becomes: "none") == "none")
        let probe = try await page.webKitView.callAsyncJavaScript("return window.__claimProbe ?? null;", contentWorld: .page) as? String
        #expect(probe == nil, "with no acknowledgement the claim reloads the document")
        #expect(page.lastClaim?.path == .timedOut)
    }

    @Test func withNoAcknowledgementTheReloadWaitsForTheClockDeadline() async throws {
        let window = Self.window()
        defer { window.close() }
        let pool = Self.pool(window)
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release) }
        let spare = try #require(await Self.settledSpare(pool))
        let clock = ClaimTestClock()
        spare.claimState.clock = clock
        _ = try await spare.webKitView.callAsyncJavaScript(
            "window.__claimProbe = 'spare'; window.__cmuxPageReceive = () => {}; return true;", contentWorld: .page)

        let provider = PageHostPoolSettingsClaimTests.RecordingProvider()
        let page = try #require(pool.claim(.settings, routes: [PageRoute(prefix: "cmux.settings.", provider: provider)],
                                           route: "#/settings/general", window: window, focus: false))
        Self.show(page, in: window)
        try await Task.sleep(for: .milliseconds(300))
        let before = try await page.webKitView.callAsyncJavaScript("return window.__claimProbe ?? null;", contentWorld: .page) as? String
        #expect(before == "spare", "no reload before the clock reaches the deadline")
        #expect(page.lastClaim == nil)

        clock.advance(by: PageWebView.claimAcknowledgementBudget)
        #expect(await Self.readAndListened(provider) == true)
        #expect(page.lastClaim?.path == .timedOut)
    }

    @Test func aHostParkedAgainRefusesTheClaimAndReloadsWithoutWaiting() async throws {
        let window = Self.window()
        defer { window.close() }
        let pool = Self.pool(window)
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release) }
        let spare = try #require(await Self.settledSpare(pool))
        // The first claim must be acknowledged, not timed out: a timeout reloads the document, and a
        // host released mid-reload is parked unloaded, so the second claim takes the plain-load path.
        // The off-window page can miss the 50 ms wall-clock budget on a loaded runner; a manual clock
        // leaves the acknowledgement as the only way the first claim ends.
        spare.claimState.clock = ClaimTestClock()
        let first = PageHostPoolSettingsClaimTests.RecordingProvider()
        let page = try #require(pool.claim(.settings, routes: [PageRoute(prefix: "cmux.settings.", provider: first)],
                                           window: window, focus: false))
        await page.waitUntilLoaded()
        #expect(page.lastClaim?.path == .acknowledged)
        #expect(await Self.readAndListened(first) == true)
        // Released untouched: parked again with the document that already ran.
        pool.dropSpare()
        pool.release(page)
        #expect(pool.spareHost === spare)
        _ = await PageTestWait.value("parked again") { (done: @escaping (Bool) -> Void) in
            if pool.isSpareReady { return done(true) }
            pool.onSpareReady = { _ in done(true) }
        }
        // The deadline never comes: only the refusal can reload.
        spare.claimState.clock = ClaimTestClock()
        _ = try await spare.webKitView.callAsyncJavaScript("window.__claimProbe = 'again'; return true;", contentWorld: .page)

        let second = PageHostPoolSettingsClaimTests.RecordingProvider()
        let again = try #require(pool.claim(.settings, routes: [PageRoute(prefix: "cmux.settings.", provider: second)],
                                            window: window, focus: false))
        Self.show(again, in: window)
        #expect(await Self.readAndListened(second) == true, "ops \(second.ops)")
        #expect(again.lastClaim?.path == .refused)
        let probe = try await again.webKitView.callAsyncJavaScript("return window.__claimProbe ?? null;", contentWorld: .page) as? String
        #expect(probe == nil)
    }

    // MARK: Helpers

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    static func pool(_ window: NSWindow) -> PageHostPool {
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(policy: policy, activity: { 0 }, isTrackingMenu: { false })
        pool.follow(window)
        pool.noteLikely()
        return pool
    }

    /// The ready spare after its document had time to run (in the app it stays parked for seconds).
    static func settledSpare(_ pool: PageHostPool) async -> PageWebView? {
        if !pool.isSpareReady {
            _ = await PageTestWait.value("page host spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
        try? await Task.sleep(for: .seconds(1))
        return pool.spareHost
    }

    static func show(_ page: PageWebView, in window: NSWindow) {
        guard let content = window.contentView else { return }
        page.frame = content.bounds
        content.addSubview(page)
    }

    static func readAndListened(_ provider: PageHostPoolSettingsClaimTests.RecordingProvider) async -> Bool? {
        let read = await PageTestWait.value("settings read through the claim's routes") { (done: @escaping (Bool) -> Void) in
            if provider.readAndListened { return done(true) }
            provider.onRecord = { if provider.readAndListened { done(true) } }
        }
        provider.onRecord = nil
        return read
    }

    /// Polls the Settings page's read-only banner (`loadFailed`, `disconnected` or `none`) until it
    /// is `expected` or 20 s pass, and returns the last state (nil: the page never rendered).
    static func banner(in host: PageWebView, becomes expected: String) async -> String? {
        var last: String?
        for _ in 0..<200 {
            let state = try? await host.webKitView.callAsyncJavaScript("""
            if (!document.querySelector('.settings')) return null;
            const banner = document.querySelector('[data-read-only]');
            if (banner) return banner.getAttribute('data-read-only');
            return document.querySelector('.content h1') ? 'none' : null;
            """, contentWorld: .page) as? String
            last = state
            if state == expected { return state }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return last
    }
}
