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
/// made with.
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

    /// The pool's spare recipe, served from this test's root. The closure is a typed local first:
    /// written inline inside `#require`, Xcode 26.6's macro expansion fails to type-check it
    /// ("failed to produce diagnostic for expression") and the whole target stops compiling.
    private func spareRecipe(_ pool: PageHostPool) throws -> PooledHostRecipe {
        let served: (PageDescriptor) -> URL? = { [root] _ in root }
        return try #require(pool.spareRecipe(servedRoot: served))
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
        let pool = PageHostPool(lowPowerMode: LowPowerMode(enabled: false), activity: { 0 }, isTrackingMenu: { false })
        let recipe = try spareRecipe(pool)
        let spare = PageWebView(recipe: recipe)
        defer { spare.close() }
        #expect(try rendersNear60(spare) == false)
    }

    /// A spare made while Low Power Mode is on renders near 60 and goes to full rate when it turns
    /// off, as the pages it serves do.
    @Test func thePoolsSpareFollowsLowPowerMode() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let lowPowerMode = LowPowerMode(enabled: true)
        let pool = PageHostPool(lowPowerMode: lowPowerMode, activity: { 0 }, isTrackingMenu: { false })
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
        let pool = PageHostPool(lowPowerMode: lowPowerMode, activity: { 0 }, isTrackingMenu: { false })
        defer { pool.dropSpare() }
        pool.spare = PageWebView(recipe: try spareRecipe(pool))
        pool.spareReady = true
        lowPowerMode.override = true
        #expect(pool.spare == nil, "the spare made at full rate stayed for claims in Low Power Mode")
        #expect(!pool.isSpareReady)
    }

    /// A page follows Low Power Mode as a browser tab does: near 60 while it is on, full rate again
    /// when it turns off, without being made again.
    @Test func aPageFollowsLowPowerMode() throws {
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
