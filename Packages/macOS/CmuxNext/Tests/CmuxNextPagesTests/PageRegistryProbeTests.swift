import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Review 17 of #37296: a private dialog (a revealed password) is drawn by a page view, which
/// `debug.page` could query or snapshot. A view that refuses probes is never a probe's target and is
/// left out of the probe listing; the app's own walks (live web reloads) still see it.
@MainActor
struct PageRegistryProbeTests {
    @Test func aPageThatRefusesProbesIsNeverTheirTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Secret</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let descriptor = PageDescriptor(id: "test.probe-page", resource: "probe-page", namespaces: [])
        let view = try #require(PageWebView(descriptor: descriptor, root: root, testRoot: true, routes: [], route: "#/"))
        defer { view.close() }
        #expect(PageRegistry.probeTarget(id: descriptor.id) === view)
        view.refusesProbes = true
        #expect(PageRegistry.probeTarget(id: descriptor.id) == nil)
        #expect(PageRegistry.probeTarget(id: descriptor.id, instance: PageRegistry.instance(of: view)) == nil)
        #expect(PageRegistry.pages(id: descriptor.id, probing: true).isEmpty)
        #expect(PageRegistry.pages(id: descriptor.id).contains { $0 === view })
    }

    /// Review 22 of #37296: a probe picked a pooled dialog page before a password dialog claimed it, and
    /// the page refused probes only from then on, so the probe's read went on. A dialog pool's view refuses
    /// probes from the turn it is made, spare or claimed.
    @Test func aDialogPoolsPageRefusesProbesFromTheStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Dialog</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let pool = OverlayDialogDrawing(drawing: CmuxDialogCenter()).pool
        pool.testRoot = root
        let (view, _) = try #require(pool.claim())
        defer { view.close() }
        #expect(view.refusesProbes)
        // Review 28 of #37296: nor does a Web Inspector, which reads the DOM and calls the page's bridge.
        #expect(!view.webView.isInspectable)
        #expect(PageRegistry.probeTarget(id: PageDescriptor.overlay.id, instance: PageRegistry.instance(of: view)) == nil)
        #expect(!PageRegistry.pages(id: PageDescriptor.overlay.id, probing: true).contains { $0 === view })
    }
}
