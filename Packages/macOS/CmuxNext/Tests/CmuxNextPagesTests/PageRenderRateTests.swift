import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// Every cmux WebKit page is made at the display's full rate (perf-lead row 23, #16424). WebKit's
/// own default renders a page at the display-rate divisor nearest 60 fps (60 on a 120 Hz display),
/// so a page that did not opt in (Settings, History, Cloud, Keybindings, the channels Home,
/// Passwords, and the pool's spare, which every pooled page is claimed from) ran its main-thread
/// rendering (scroll handlers, rAF, rows a virtual list mounts, JS-driven fades) every other refresh.
///
/// The rate is fixed when the page is made and never changes live: in Low Power Mode WebKit halves
/// every page's rate by itself (its `ThrottlingReason::LowPowerMode`, live, in both directions), so
/// the page keeps full rate here. These read the WebKit preference of the web view a page is made
/// with; the cadence itself (and WebKit's Low Power Mode halving) is
/// `scripts/cmux-next/bench-page-cadence.py`.
@MainActor @Suite(.serialized)
struct PageRenderRateTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.render-rate", resource: "render-rate", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-rate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// Whether `preferences` keep WebKit's near-60 fps rate. It fails, rather than answering, when
    /// this WebKit lists no such feature: then no rate this code sets has any effect either, and
    /// the failure names that cause.
    private func rendersNear60(_ preferences: WKPreferences) throws -> Bool {
        let near60 = preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature)
        return try #require(near60, "WebKit has no \(WebKitRenderRate.near60FPSFeature) feature on this macOS")
    }

    @Test func aPageMadeWithTheStandardOptionsRendersAtTheDisplaysFullRate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let made = PageWebView(descriptor: descriptor, root: root, routes: [], options: .standard, chromium: nil)
        let view = try #require(made)
        defer { view.close() }
        #expect(try rendersNear60(view.webKitView.configuration.preferences) == false,
                "a standard page renders near 60 fps: half the rate of a 120 Hz display")
    }

    /// The configuration every page host is made from: a page's own initializer and the pool's
    /// spare recipe (``PageWebView/pooledHostRecipe(_:options:)``) both build it here, with the
    /// pool's standard options.
    @Test func theConfigurationEveryPageHostIsMadeFromRendersAtTheDisplaysFullRate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = PageSchemeHandler(page: descriptor, root: root, dynamicSource: nil)
        let host = PageWebView.hostConfiguration(handler: handler, documentAttributes: [:], options: .standard)
        #expect(try rendersNear60(host.configuration.preferences) == false,
                "the page host configuration (and so the pool's spare) renders near 60 fps")
    }

    /// The one page that asks for WebKit's rate nearest 60 fps keeps it: the agent pane's debug
    /// `capped` rate (AgentPanePageHost).
    @Test func aPageThatAsksForTheCappedRateRendersNear60() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = PageSchemeHandler(page: descriptor, root: root, dynamicSource: nil)
        let host = PageWebView.hostConfiguration(handler: handler, documentAttributes: [:],
                                                 options: PageEngineOptions(fullFrameRate: false))
        #expect(try rendersNear60(host.configuration.preferences))
    }
}
