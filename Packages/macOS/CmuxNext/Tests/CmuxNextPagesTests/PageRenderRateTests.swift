import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// Every cmux page renders at the display's full refresh outside Low Power Mode (perf-lead row 22,
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

    /// A Settings root for the pool to serve, registered once per process (the first registration
    /// wins, `PageID.registerBundledRoot`); a bundled Settings build, when present, is used instead.
    private static let settingsRoot: URL? = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("page-rate-settings-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<!doctype html><title>Settings</title>".utf8).write(to: directory.appendingPathComponent("index.html"))) != nil
        else { return nil }
        PageID.registerBundledRoot(directory, for: PageDescriptor.settings.id)
        return directory
    }()

    /// Whether `view` keeps WebKit's near-60 fps rate. It fails, rather than answering, when this
    /// WebKit lists no such feature: then the product's rate change does nothing either, and the
    /// failure names that cause.
    private func rendersNear60(_ view: PageWebView) throws -> Bool {
        try #require(view.webKitView.configuration.preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature),
                     "WebKit has no \(WebKitRenderRate.near60FPSFeature) feature on this macOS")
    }

    private func page(_ options: PageEngineOptions = .standard) throws -> PageWebView {
        try #require(PageWebView(descriptor: descriptor, root: root, routes: [], options: options, chromium: nil))
    }

    @Test func aPageMadeWithTheStandardOptionsRendersAtTheDisplaysFullRate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try page()
        defer { view.close() }
        view.followLowPowerMode(LowPowerMode(enabled: false))
        #expect(try rendersNear60(view) == false)
    }

    /// The pool's spare (Settings, History and Cloud open on one), made the way the pool builds it:
    /// the pool's own options, its recipe, then the view.
    @Test func thePoolsSpareRendersAtTheDisplaysFullRate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try #require(Self.settingsRoot)
        let pool = PageHostPool(activity: { 0 }, isTrackingMenu: { false })
        let recipe = try #require(PageWebView.pooledHostRecipe(.settings, options: pool.options))
        let spare = PageWebView(recipe: recipe)
        defer { spare.close() }
        spare.followLowPowerMode(LowPowerMode(enabled: false))
        #expect(try rendersNear60(spare) == false)
    }

    /// A page follows Low Power Mode as a browser tab does: near 60 while it is on, full rate again
    /// when it turns off, without being made again.
    @Test func aPageFollowsLowPowerMode() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try page()
        defer { view.close() }
        let lowPowerMode = LowPowerMode(enabled: false)
        view.followLowPowerMode(lowPowerMode)
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
        capped.followLowPowerMode(LowPowerMode(enabled: false))
        #expect(try rendersNear60(capped))
        let full = try page(PageEngineOptions(renderRate: .full))
        defer { full.close() }
        let lowPowerMode = LowPowerMode(enabled: false)
        full.followLowPowerMode(lowPowerMode)
        lowPowerMode.override = true
        #expect(try rendersNear60(full) == false)
    }

    @Test(arguments: [(PageRenderRate.display, false, true), (.display, true, false), (.full, true, true),
                      (.full, false, true), (.capped, false, false), (.capped, true, false)])
    func theRateRule(rate: PageRenderRate, lowPowerMode: Bool, fullRate: Bool) {
        #expect(PageWebView.rendersAtFullRate(rate, lowPowerMode: lowPowerMode) == fullRate)
    }
}
