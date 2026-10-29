import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing
import WebKit

/// No cmux page renderer before the page first shows (feature `pageRendererAtFirstShow`).
/// A page the host opens with ``WebUIHost/startsPagesAtFirstShow`` makes no engine call (no load, no
/// script, so no WebKit WebContent process) and asks for no Chromium page until it is in a window its
/// visibility node says is visible, with no hidden ancestor. A preload for the preload slot is the
/// one page that starts hidden (Chrome's `kPreloadOnMakeVisible` preload).
@MainActor @Suite(.serialized)
struct PageLazinessTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.page-laziness", resource: "page-laziness", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-laziness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A window ordered in whose visibility node reads `state` (AppKit reports the off-screen test
    /// window covered); `refresh()` on the returned source reads it again.
    private func makeWindow(_ state: @escaping @MainActor () -> Visibility = { .visible }) -> (NSWindow, WindowVisibilitySource) {
        let window = PagePreloadPageTests.shownWindow()
        return (window, WindowVisibilitySource.of(window, read: { _ in state() }))
    }

    private func shownWindow() -> NSWindow { makeWindow().0 }

    /// The WebKit pid of the page's web view; 0 while it has no WebContent process.
    private func webProcess(_ view: PageWebView) -> Int32 {
        let webView = view.webView
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return 0 }
        return (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }

    /// A few main-actor turns: the page's own first tasks (its ui-scale observation) run.
    private func settle() async {
        let work = MainWorkScheduler(budget: MainFrameBudget())
        for _ in 0..<5 { await work.apply(.background, owner: "PageLazinessTests.settle") { () -> Void in } }
    }

    private func makeHost(_ hosting: FakeChromiumHosting?, lazy: Bool = true) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: nil,
                  memory: QuietMemoryRegistry(),
                  deadlines: LifecycleDeadlineRig.never, startsPagesAtFirstShow: lazy)
    }

    @Test func aWebKitPageStartsNoDocumentBeforeItsFirstShow() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/start")))
        defer { host.close(view) }
        let spy = SpyPageHostBridge()
        view.scriptTarget.bridge = spy
        await settle()
        #expect(view.awaitsFirstShow)
        #expect(view.webView.url == nil, "the hidden page loaded, which starts its WebContent process")
        #expect(spy.evaluated.isEmpty, "a script reached the hidden page: WebKit launches its process to run it")
        #expect(webProcess(view) == 0, "the hidden page has a WebContent process")
        let window = shownWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(!view.awaitsFirstShow)
        #expect(view.webView.url == descriptor.url(route: "#/start"))
        view.evaluate("1")
        #expect(spy.evaluated.last == "1", "a started page runs its scripts")
    }

    /// The host's own calls into a page that has not shown (New Tab places, the debug verbs, a
    /// discard's scroll read) make no engine call.
    @Test func hostCallsBeforeTheFirstShowReachNoEngine() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let spy = SpyPageHostBridge()
        view.scriptTarget.bridge = spy
        view.evaluate("window.x = 1")
        view.send(command: PageNativeOp.focusContent)
        #expect(await view.callPageFunction("return 1;") == nil)
        await #expect(throws: PageScriptError.notStarted) { _ = try await view.callPageScript("return 1;") }
        #expect(await view.snapshot() == nil)
        await settle()
        #expect(spy.evaluated.isEmpty)
        #expect(webProcess(view) == 0)
    }

    @Test func aChromiumPageAsksForNoRendererBeforeItsFirstShow() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/start")))
        defer { host.close(view) }
        await settle()
        #expect(view.engineDecision == .chromium)
        #expect(view.chromiumStart == nil)
        #expect(hosting.made.isEmpty, "the hidden page made a Chromium page, which starts a renderer")
        #expect(webProcess(view) == 0, "the hidden Chromium page's WebKit view has a WebContent process")
        let window = shownWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(hosting.made.count == 1)
        #expect(page.loaded == [descriptor.url(route: "#/start")])
    }

    /// A tab of a hidden workspace: its node (tab, pane, workspace) is hidden, so the page waits in
    /// a shown window and starts when the workspace shows.
    @Test func aPageOfAHiddenWorkspaceStartsWhenTheWorkspaceShows() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = shownWindow()
        defer { window.close() }
        let workspace = VisibilityNode(root: "workspace", own: .hidden)
        let tab = VisibilityNode("tab", own: .visible, parent: workspace)
        view.followAppearance(DesignSettings.shared.signals, node: tab)
        window.contentView?.addSubview(view)
        #expect(view.awaitsFirstShow)
        #expect(view.webView.url == nil)
        workspace.set(.visible)
        #expect(!view.awaitsFirstShow)
        #expect(view.webView.url == descriptor.url())
    }

    /// The page view itself unhidden while its workspace is still hidden: not shown yet.
    @Test func aPageUnhiddenInAHiddenWorkspaceWaits() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = shownWindow()
        defer { window.close() }
        let workspace = VisibilityNode(root: "workspace", own: .hidden)
        view.followAppearance(DesignSettings.shared.signals, node: VisibilityNode("tab", own: .visible, parent: workspace))
        view.isHidden = true
        window.contentView?.addSubview(view)
        view.isHidden = false
        #expect(view.awaitsFirstShow, "a page of a hidden workspace started its renderer")
        workspace.set(.visible)
        #expect(!view.awaitsFirstShow)
    }

    /// A page view hidden in a shown window (its pane shows another tab) waits; its unhide starts it.
    @Test func aHiddenPageViewStartsWhenItIsUnhidden() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = shownWindow()
        defer { window.close() }
        view.isHidden = true
        window.contentView?.addSubview(view)
        #expect(view.awaitsFirstShow)
        view.isHidden = false
        #expect(!view.awaitsFirstShow)
    }

    /// A tab moved from a hidden workspace's pane to the shown pane of the same window: the window
    /// does not change and the view is never unhidden; the pane selects the tab (its node moves
    /// under the shown pane and turns visible) and shows the view.
    @Test func aPageMovedFromAHiddenPaneToAShownOneStarts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = shownWindow()
        defer { window.close() }
        let hiddenPaneNode = VisibilityNode(root: "pane.hidden", own: .hidden)
        let shownPaneNode = VisibilityNode(root: "pane.shown", own: .visible)
        let tab = VisibilityNode("tab", own: .visible, parent: hiddenPaneNode)
        view.followAppearance(DesignSettings.shared.signals, node: tab)
        let hiddenPane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let shownPane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(hiddenPane)
        window.contentView?.addSubview(shownPane)
        hiddenPane.addSubview(view)
        #expect(view.awaitsFirstShow)
        try tab.attach(to: shownPaneNode)
        shownPane.addSubview(view)
        #expect(!view.awaitsFirstShow, "the page moved into the shown pane never loads")
        #expect(view.webView.url == descriptor.url())
    }

    /// A covered window (another window in front, another Space) does not show its pages; the page
    /// starts when its window's node turns visible (Chrome's WasShown follows occlusion).
    @Test func aPageInACoveredWindowStartsWhenTheWindowShows() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let state = VisibilityBox(.occluded)
        let (window, source) = makeWindow { state.value }
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(view.awaitsFirstShow == !WindowDrawPolicy.drawsWhenOccluded, "a page in a covered window started its renderer")
        state.value = .visible
        source.refresh()
        #expect(!view.awaitsFirstShow)
        #expect(view.webView.url == descriptor.url())
    }

    /// A panel that is not ordered in (a picker made ahead): AppKit's own answer keeps its page waiting.
    @Test func aPageInAWindowNotOrderedInWaits() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(!window.isVisible)
        // An automation launch counts covered windows as shown (``WindowDrawPolicy/drawsWhenOccluded``).
        #expect(view.awaitsFirstShow == !WindowDrawPolicy.drawsWhenOccluded, "a page in a window that is not ordered in started its renderer")
    }

    @Test func aWindowShowsPagesOnlyWhenVisible() {
        #expect(PageWebView.windowShowsPages(.visible, drawsWhenOccluded: false))
        #expect(!PageWebView.windowShowsPages(.occluded, drawsWhenOccluded: false))
        #expect(!PageWebView.windowShowsPages(.hidden, drawsWhenOccluded: false))
        #expect(PageWebView.windowShowsPages(.occluded, drawsWhenOccluded: true), "automation draws covered windows")
        #expect(!PageWebView.windowShowsPages(.hidden, drawsWhenOccluded: true))
    }

    /// The host moved the page before it showed: the first show loads the last route asked for.
    @Test func aRouteOpenedBeforeTheFirstShowIsTheOneThatLoads() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/a")))
        defer { host.close(view) }
        view.open(route: "/b")
        view.reload()
        #expect(view.webView.url == nil, "a route or reload before the first show loaded the hidden page")
        let window = shownWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(view.webView.url == descriptor.url(route: "#/b"))
    }

    @Test func aPageClosedBeforeItShowedNeverStarts() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        host.close(view)
        #expect(!view.awaitsFirstShow)
        let window = shownWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(view.chromiumStart == nil)
        #expect(hosting.made.isEmpty)
    }

    /// With the feature off a page starts as it opens, as before.
    @Test func withoutTheFeatureAPageStartsAsItOpens() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil, lazy: false)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        #expect(!view.awaitsFirstShow)
        #expect(view.webView.url == descriptor.url())
    }

    /// A preload (``PageOpenRequest/parked``) loads as it opens even on a lazy host: it waits hidden in
    /// the preload slot's parking and is never shown before its claim. The slot preloads a page only
    /// after one of its kind opened (`PagePreloads`), Chrome's `kPreloadOnMakeVisible`.
    @Test func aParkedPreloadStartsAsItOpensOnALazyHost() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(nil)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], parked: true)))
        defer { host.close(view) }
        #expect(!view.awaitsFirstShow)
        #expect(view.webView.url == descriptor.url())
    }
}

/// Records the scripts that reach a page's engine.
@MainActor private final class SpyPageHostBridge: PageHostBridge {
    let engine = PageHostEngine.webKit
    private(set) var evaluated: [String] = []

    func install(_ handler: @escaping PageHostHandler) {}
    func evaluate(_ script: String) { evaluated.append(script) }
    func uninstall() {}
}

/// A window state a test flips.
@MainActor private final class VisibilityBox {
    var value: Visibility
    init(_ value: Visibility) { self.value = value }
}
