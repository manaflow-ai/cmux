import AppKit
import CmuxNextCompat
@testable import CmuxNextPages
import Foundation
import Testing

/// Cmd-, with Chromium as the default engine (2026-11-15: "the tab shows up first, and then like a
/// second later, the settings page actually shows up"). Every open built a Chromium page: its first
/// frame came 270-500 ms after the key on a fleet Mac, while the tab already showed. Settings now
/// opens from the page host pool's parked WebKit document whatever `browser.defaultEngine` says
/// (``PageWebKitReason/pooledInstantOpen``), and a Chromium open of another pooled page keeps that
/// spare.
@MainActor @Suite(.serialized) struct SettingsOpensFromParkedSpareTests {
    /// `PageFactory.settingsEngineOptions` (CmuxNextApp; `PageChromiumCoverageTests` checks the app uses it).
    static let settingsOptions = PageEngineOptions(requiresWebKit: .pooledInstantOpen)

    /// The budget of one claim of the parked spare on the main thread (the open's key turn).
    static let claimBudgetMilliseconds = 10.0
    /// The budget from the claim to the parked document's acknowledgement: it shows the route with no
    /// reload, so it paints in the next frames (a reload, as a cold Chromium build, took 270-500 ms).
    /// `swift test` windows get no compositor frames (``PageHostPoolVisibilityTests``), so the paint
    /// itself is measured in the app on a fleet Mac (the fix commit gives the numbers).
    static let acknowledgementBudgetMilliseconds = Double(PageWebView.claimAcknowledgementBudget.components.seconds) * 1_000
        + Double(PageWebView.claimAcknowledgementBudget.components.attoseconds) / 1e15

    /// The app's decision with Chromium as the default engine and available.
    static func chromiumDefault(_ page: PageDescriptor, _ options: PageEngineOptions) -> PageEngineDecision {
        PageEnginePolicy(preference: .chromium, chromiumAvailable: true).decide(for: page, options: options)
    }

    @Test func settingsShowsInWebKitWhenChromiumIsTheDefault() {
        #expect(Self.chromiumDefault(.settings, Self.settingsOptions) == .webKit(.pooledInstantOpen))
        #expect(Self.chromiumDefault(.history, .standard) == .chromium, "History still follows the default engine")
    }

    /// Red before the fix: the History claim dropped the spare, so the Settings claim found none.
    @Test func aChromiumOpenOfAnotherPageKeepsTheSettingsSpare() async throws {
        let (window, pool) = try await Self.readyPool()
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release); window.close() }
        #expect(pool.claim(.history, routes: [], options: .standard, window: window, focus: false) == nil,
                "History shows in Chromium: made fresh, not from the WebKit spare")
        #expect(pool.isSpareReady, "a Chromium claim of another page dropped the Settings spare")
        let page = pool.claim(.settings, routes: [], route: "#/settings/general", options: Self.settingsOptions,
                              window: window, focus: false)
        #expect(page != nil, "Settings found no parked spare: its open builds a page cold")
    }

    /// The perf budget of the open: the claim's main-thread time, and the document taking the claim
    /// with no reload.
    @Test func settingsClaimedFromTheSpareTakesItWithinItsBudget() async throws {
        let (window, pool) = try await Self.readyPool()
        defer { pool.dropSpare(); pool.claimedHosts.forEach(pool.release); window.close() }
        // A parked spare waits seconds or more in the app: let its document settle as it would.
        try await Task.sleep(for: .milliseconds(500))
        let provider = RecordingPageProvider()
        let start = ContinuousClock.now
        let page = try #require(pool.claim(.settings, routes: [PageRoute(prefix: "cmux.settings.", provider: provider)],
                                           route: "#/settings/general", options: Self.settingsOptions,
                                           window: window, focus: false))
        let claimed = Self.milliseconds(since: start)
        while page.lastClaim == nil, Self.milliseconds(since: start) < 2_000 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let outcome = try #require(page.lastClaim, "the claimed Settings document never answered its claim")
        print("SETTINGS_OPEN_BUDGET claim_ms=\(claimed) claim=\(outcome.path.rawValue)@\(outcome.milliseconds)")
        #expect(pool.claims.last?.spare == true)
        #expect(claimed < Self.claimBudgetMilliseconds, "claim took \(claimed) ms on the main thread")
        #expect(outcome.path == .acknowledged, "the parked document reloaded instead of taking the claim")
        #expect(outcome.milliseconds < Self.acknowledgementBudgetMilliseconds)
    }

    /// A pool made as the app makes it (Settings' options), Chromium the default, with its spare ready.
    private static func readyPool() async throws -> (NSWindow, PageHostPool) {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()), policy: policy,
                                options: settingsOptions, activity: { 0 }, isTrackingMenu: { false },
                                engineDecision: chromiumDefault)
        pool.follow(window)
        pool.noteLikely()
        if !pool.isSpareReady {
            _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
        try #require(pool.isSpareReady, "no Settings spare with Chromium as the default engine")
        return (window, pool)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
