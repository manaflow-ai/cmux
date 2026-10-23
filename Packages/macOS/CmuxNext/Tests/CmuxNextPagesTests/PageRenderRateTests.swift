import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// Every cmux page scrolls at the display's full refresh (perf-lead row 22, #16424). WebKit's
/// default renders a page at the display-rate divisor nearest 60 fps (60 on a 120 Hz display, 80
/// on 160 Hz), so a page that did not opt in (Settings, History, Cloud, Keybindings, the channels
/// Home, Passwords, and every pooled spare) drew every other refresh while it scrolled: rows a
/// virtual list mounts, scroll-edge fades, sticky headers and thumbs all landed at half rate.
/// These read the live WebKit preference of the web view a page is made with.
@MainActor
struct PageRenderRateTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.render-rate", resource: "render-rate", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-rate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// Whether `preferences` keep WebKit's near-60 fps rate; fails when this WebKit has no such
    /// feature (every supported macOS has it: 14, 15, 26, 27).
    private func rendersNear60(_ preferences: WKPreferences) throws -> Bool {
        try #require(preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature),
                     "WebKit has no \(WebKitRenderRate.near60FPSFeature) feature")
    }

    @Test func aPageMadeWithTheStandardOptionsRendersAtTheDisplaysFullRate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        defer { view.close() }
        #expect(try rendersNear60(view.webKitView.configuration.preferences) == false)
    }

    /// The pool's spares (Settings, History, Cloud open on one) are made the same way.
    @Test func aPooledSparesConfigurationRendersAtTheDisplaysFullRate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = PageWebView.hostConfiguration(handler: PageSchemeHandler(resolve: { _ in nil }),
                                                 documentAttributes: [:], options: .standard)
        #expect(try rendersNear60(host.configuration.preferences) == false)
    }

    /// The one page that may cap: the agent pane under its debug `capped` render rate.
    @Test func aPageThatCapsItsRateRendersNear60() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [],
                                            options: PageEngineOptions(capsFrameRate: true), chromium: nil))
        defer { view.close() }
        #expect(try rendersNear60(view.webKitView.configuration.preferences))
    }
}
