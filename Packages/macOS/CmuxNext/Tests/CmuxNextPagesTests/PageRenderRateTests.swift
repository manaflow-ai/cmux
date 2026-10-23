import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// Every cmux page renders at the display's full refresh outside Low Power Mode (perf-lead row 23, WebKit pages only,
/// #16424), by the same rule as browser tabs. WebKit's default renders a page at the display-rate
/// divisor nearest 60 fps (60 on a 120 Hz display, 80 on 160 Hz), so a page that did not opt in
/// (Settings, History, Cloud, Keybindings, the channels Home, Passwords, and every pooled spare)
/// ran its main-thread rendering (scroll handlers, rAF, rows a virtual list mounts, JS-driven
/// fades) every other refresh. These read the live WebKit preference of the web view a page is
/// made with. The preference is not the cadence: on cmux20 (macOS 27, 120 Hz) a shown page whose
/// preference was written to near60 later still rendered at 120 fps. A test here that changes Low
/// Power Mode on a live page says only that the preference was written; the cadence is
/// `scripts/cmux-next/bench-page-cadence.py --live`.
@MainActor @Suite(.serialized)
struct PageRenderRateTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.render-rate", resource: "render-rate", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-rate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// Whether `view` keeps WebKit's near-60 fps rate. It fails, rather than answering, when this
    /// WebKit lists no such feature: then the product's rate change does nothing either, and the
    /// failure names that cause.
    private func rendersNear60(_ view: PageWebView) throws -> Bool {
        try #require(view.webKitView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature),
                     "WebKit has no \(WebKitRenderRate.near60FPSFeature) feature on this macOS")
    }

    private func page(_ options: PageEngineOptions = .standard,
                      lowPowerMode: LowPowerMode = LowPowerMode(enabled: false)) throws -> PageWebView {
        try #require(PageWebView(descriptor: descriptor, root: root, routes: [], options: options, chromium: nil,
                                 lowPowerMode: lowPowerMode))
    }

    /// A pool whose spare's pages are served from this test's root, not a process-wide
    /// registration. The closure is a typed local first: written inline inside an expression
    /// Xcode 26.6's type checker gave up on similar closures ("failed to produce diagnostic").
    private func makePool(_ lowPowerMode: LowPowerMode, policy: PageHostPool.Policy = PageHostPool.Policy()) -> PageHostPool {
        let served: (PageDescriptor) -> URL? = { [root] _ in root }
        return PageHostPool(policy: policy, lowPowerMode: lowPowerMode, activity: { 0 }, isTrackingMenu: { false },
                            servedRoot: served)
    }

    /// The pool's spare recipe (its options, Low Power Mode and served root).
    private func spareRecipe(_ pool: PageHostPool) throws -> PooledHostRecipe {
        try #require(pool.spareRecipe())
    }

    @Test func aPageMadeWithTheStandardOptionsRendersAtTheDisplaysFullRate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try page()
        defer { view.close() }
        #expect(try rendersNear60(view) == false)
    }

    /// The pool's spare (Settings, History and Cloud open on one), made the way the pool builds it:
    /// the pool's recipe (its options and Low Power Mode), then the view. The pages are served from
    /// this test's root, not a process-wide registration.
    @Test func thePoolsSpareRendersAtTheDisplaysFullRate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = makePool(LowPowerMode(enabled: false))
        let recipe = try spareRecipe(pool)
        let spare = PageWebView(recipe: recipe)
        defer { spare.close() }
        #expect(try rendersNear60(spare) == false)
    }

    /// A spare made while Low Power Mode is on has the near-60 preference, and the preference is
    /// written to full rate when it turns off. Only the preference: whether a live page's cadence
    /// follows it is not shown (the pool drops such a spare and makes a new one anyway).
    @Test func thePoolsSpareWritesTheRatePreferenceWhenLowPowerModeChanges() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let lowPowerMode = LowPowerMode(enabled: true)
        let pool = makePool(lowPowerMode)
        let recipe = try spareRecipe(pool)
        let spare = PageWebView(recipe: recipe)
        defer { spare.close() }
        #expect(try rendersNear60(spare))
        lowPowerMode.override = false
        #expect(try rendersNear60(spare) == false)
    }

    /// WebKit holds the rate a page is made with: on cmux20 (macOS 27, 120 Hz) a shown page whose
    /// preference was written to near60 later still rendered at 120 fps. So a Low Power Mode change
    /// drops the parked spare, and the next claim gets one made at the new rate.
    @Test func aLowPowerModeChangeDropsTheSpare() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let lowPowerMode = LowPowerMode(enabled: false)
        let pool = makePool(lowPowerMode)
        defer { pool.dropSpare() }
        pool.spare = PageWebView(recipe: try spareRecipe(pool))
        pool.spareReady = true
        lowPowerMode.override = true
        #expect(pool.spare == nil, "the spare made at full rate stayed for claims in Low Power Mode")
        #expect(!pool.isSpareReady)
    }

    /// A claimed host that comes back untouched returns to the spare slot only when it was made at
    /// the current rate.
    @Test(arguments: [false, true])
    func aReturnedHostIsASpareAgainOnlyAtTheCurrentRate(lowPowerModeChanged: Bool) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let lowPowerMode = LowPowerMode(enabled: false)
        let pool = makePool(lowPowerMode)
        defer { pool.dropSpare() }
        pool.follow(window)
        let host = PageWebView(recipe: try spareRecipe(pool))
        pool.claimed[ObjectIdentifier(host)] = PageHostPool.WeakHost(host, generation: pool.rateGeneration)
        if lowPowerModeChanged { lowPowerMode.override = true }
        pool.release(host)
        #expect((pool.spare === host) == !lowPowerModeChanged,
                "returned host back in the spare slot: \(pool.spare === host), Low Power Mode changed: \(lowPowerModeChanged)")
    }

    /// A Low Power Mode change while a build has parked its spare (during a turn after the park or
    /// during the load) drops that spare, and lowPowerModeChanged cannot schedule a build while
    /// this one runs. The build must then schedule the next spare itself on its way out; it did so
    /// only for a change before the park, so the pool was left with no spare and no build and the
    /// next Settings, History or Cloud open loaded cold.
    @Test func aChangeAfterTheBuildParkedItsSpareStartsTheNextBuild() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let lowPowerMode = LowPowerMode(enabled: false)
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = makePool(lowPowerMode, policy: policy)
        defer { pool.dropSpare() }
        var changed = false
        let started = await PageTestWait.value("the next build after the change", seconds: 10) { (done: @escaping (Bool) -> Void) in
            pool.onSpan = { name, _ in
                switch name {
                case "pool.makeSpare.park" where !changed:
                    changed = true
                    // The change lands in the turn the build awaits after the park, as a real one
                    // can (never inside the synchronous park itself).
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { lowPowerMode.override = true }
                    }
                case "pool.makeSpare.configure" where changed:
                    done(true)
                default:
                    break
                }
            }
            pool.follow(window)
            pool.noteLikely()
        }
        #expect(changed, "the first build never parked its spare")
        #expect(started == true, "after a change during the build, the pool made no new spare")
        // The next build stops at its park guard instead of loading into a closed window.
        pool.onSpan = nil
        pool.isLikely = false
    }

    /// A page writes its rate preference as Low Power Mode changes, as a browser tab does: near 60
    /// while it is on, full rate again when it turns off. Only the preference: on macOS 27 a shown
    /// page's cadence did not follow a live write to near60, and the other direction is unmeasured
    /// (perf-lead row 23, open for shown pages and tabs).
    @Test func aPageWritesTheRatePreferenceWhenLowPowerModeChanges() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let lowPowerMode = LowPowerMode(enabled: false)
        let view = try page(lowPowerMode: lowPowerMode)
        defer { view.close() }
        #expect(try rendersNear60(view) == false)
        lowPowerMode.override = true
        #expect(try rendersNear60(view))
        lowPowerMode.override = nil
        #expect(try rendersNear60(view) == false)
    }

    /// The agent pane sets its own rate: capped stays near 60 outside Low Power Mode, full stays
    /// full inside it.
    @Test func aPageWithItsOwnRateIgnoresLowPowerMode() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let capped = try page(PageEngineOptions(renderRate: .capped))
        defer { capped.close() }
        #expect(try rendersNear60(capped))
        let lowPowerMode = LowPowerMode(enabled: false)
        let full = try page(PageEngineOptions(renderRate: .full), lowPowerMode: lowPowerMode)
        defer { full.close() }
        lowPowerMode.override = true
        #expect(try rendersNear60(full) == false)
    }
}

/// The rate rule alone: no page and no file root (the suite above makes a root per test).
@MainActor
struct PageRenderRateRuleTests {
    @Test(arguments: [(PageRenderRate.display, false, true), (.display, true, false), (.full, true, true),
                      (.full, false, true), (.capped, false, false), (.capped, true, false)])
    func theRateRule(rate: PageRenderRate, lowPowerMode: Bool, fullRate: Bool) {
        #expect(PageWebView.rendersAtFullRate(rate, lowPowerMode: lowPowerMode) == fullRate)
    }
}
