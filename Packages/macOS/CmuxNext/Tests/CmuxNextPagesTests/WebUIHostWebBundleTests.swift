import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// A change of the served web files through the page host (p13-webui-071, p13-webui.md 3.C): only the
/// shown page is asked and reloaded; hidden and frozen pages get no call, stay frozen, and reload once
/// when they show, as Chrome loads a background tab marked `SetNeedsReload` only when it is shown
/// (content/browser/renderer_host/navigation_controller_impl.cc).
@MainActor @Suite(.serialized)
struct WebUIHostWebBundleTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.web-bundle", resource: "web-bundle", processGroup: .privileged, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("web-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// `count` loaded Chromium pages in one window: the first shows, the others are hidden tabs, frozen.
    private func openPages(_ count: Int, host: WebUIHost) async throws -> (NSWindow, [PageWebView]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        var views: [PageWebView] = []
        for index in 0..<count {
            let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
            await view.chromiumStart?.value
            view.frame = container.bounds
            view.isHidden = index > 0
            container.addSubview(view)
            view.loaded = true
            if index > 0 { #expect(view.freezePage()) }
            views.append(view)
        }
        return (window, views)
    }

    private func fake(_ view: PageWebView) throws -> FakeChromiumPage {
        try #require(view.chromiumPage as? FakeChromiumPage)
    }

    @Test func oneShownAndFourFrozenPagesGiveOneAskAndOneReloadAndTheFrozenOnesReloadWhenShown() async throws {
        let host = WebUIHost(chromium: FakeChromiumHosting(), openPanel: nil, memory: QuietMemoryRegistry(),
                             clock: PageTestClock.never)
        let (window, views) = try await openPages(5, host: host)
        defer {
            for view in views { host.close(view) }
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        let shown = views[0], frozen = Array(views.dropFirst())
        #expect(views.allSatisfy { $0.chromiumPage != nil })

        // The safe point asks the shown page only.
        #expect(host.shownBundlePages.map { ObjectIdentifier($0) } == [ObjectIdentifier(shown)])
        let asked = try fake(shown).evaluations.count
        #expect(await shown.askBundleSwap() == nil)
        #expect(try fake(shown).evaluations.count == asked + 1)

        // The swap: one reload now, no call into a frozen page, which stays frozen.
        let before = try frozen.map { page -> (steps: Int, evaluations: Int, reloads: Int) in
            let engine = try fake(page)
            return (steps: engine.lifecycleSteps.count, evaluations: engine.evaluations.count, reloads: engine.reloads)
        }
        let shownReloads = try fake(shown).reloads
        #expect(host.webBundleDidChange() == 1)
        #expect(try fake(shown).reloads == shownReloads + 1)
        for (index, page) in frozen.enumerated() {
            let engine = try fake(page)
            #expect(engine.reloads == before[index].reloads, "a frozen page reloaded")
            #expect(engine.evaluations.count == before[index].evaluations, "a frozen page was called into")
            #expect(engine.lifecycleSteps.count == before[index].steps, "the swap thawed a frozen page")
            #expect(page.bundleStale)
        }

        // A tab switch shows one: it thaws and reloads in its show; the others still wait.
        frozen[0].isHidden = false
        #expect(try fake(frozen[0]).reloads == before[0].reloads + 1)
        #expect(!frozen[0].bundleStale)
        for (index, page) in frozen.enumerated().dropFirst() {
            #expect(try fake(page).reloads == before[index].reloads && page.bundleStale)
        }
        // Shown again later: no second reload.
        frozen[0].isHidden = true
        frozen[0].isHidden = false
        #expect(try fake(frozen[0]).reloads == before[0].reloads + 1)
        withExtendedLifetime(window) {}
    }

    @Test func aDiscardedPageIsNotMarkedItsRestoreLoadsTheNewFiles() async throws {
        let host = WebUIHost(chromium: FakeChromiumHosting(), openPanel: nil, memory: QuietMemoryRegistry(),
                             clock: PageTestClock.never)
        let (window, views) = try await openPages(2, host: host)
        defer {
            for view in views { host.close(view) }
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        let hidden = views[1]
        host.webBundleDidChange()
        #expect(hidden.bundleStale)
        #expect(hidden.discardPage(decoder: PageSnapshotEncoder(start: { _, done in done(nil) }, decode: { _, done in done(nil) })))
        #expect(!hidden.bundleStale, "a discarded page kept its mark and would load twice at its restore")
        #expect(!hidden.bundleHasDocument)
        host.webBundleDidChange()
        #expect(!hidden.bundleStale)
        withExtendedLifetime(window) {}
    }
}
