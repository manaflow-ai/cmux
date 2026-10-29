import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// A page shown in Chromium makes no WKWebView: its WebKit engine
/// (``PageWebKitEngine``) is built only when it falls back, in the turn it does. The calls a host
/// makes while the Chromium page is on its way reach no engine and build none.
@MainActor
struct PageWebKitAbsenceTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.webkit-absence", resource: "webkit-absence", processGroup: .solo, namespaces: [])
    /// The agent page as the page host knows it (`PageDescriptor.agent` lives in CmuxNextAgentPane).
    private let agent = PageDescriptor(id: "cmux.agent", resource: "agent-pane", processGroup: .agent, namespaces: ["cmux.agent."])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-webkit-absence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// The agent page's root for this process. The first registration wins for the life of the
    /// process (`PageID.registerBundledRoot`) and every package test target shares it, so this is the
    /// registered root when there is one, else a fixture registered here and never deleted.
    static let agentRoot: URL? = {
        let id = "cmux.agent"
        if let registered = PageID.bundledRoot(for: id) { return registered }
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-page-webkit-absence-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              (try? Data("<!doctype html><title>Agent</title>".utf8).write(to: directory.appending(path: "index.html"))) != nil
        else { return nil }
        PageID.registerBundledRoot(directory, for: id)
        return PageID.bundledRoot(for: id)
    }()

    /// How many WKWebViews are in `view`'s subtree, `view` included.
    static func webKitViews(in view: NSView) -> Int {
        (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + webKitViews(in: $1) }
    }

    private func makeHost(_ hosting: FakeChromiumHosting) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never)
    }

    @Test func aChromiumPageHasNoWebKitViewBeforeOrAfterItAttaches() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/a")))
        defer { host.close(view) }
        #expect(view.engineDecision == .chromium)
        #expect(view.webKitPieces == nil)
        #expect(Self.webKitViews(in: view) == 0)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(page.loaded == [descriptor.url(route: "#/a")])
        #expect(view.showsChromium)
        #expect(view.webKitPieces == nil)
        #expect(Self.webKitViews(in: view) == 0)
    }

    /// The agent chat page, which shares a WebKit process when it shows in WebKit, joins no group
    /// and makes no WKWebView in Chromium.
    @Test func anAgentPageInChromiumHasNoWebKitView() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = try #require(Self.agentRoot)
        let hosting = FakeChromiumHosting()
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let host = WebUIHost(chromium: hosting, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never,
                             processGroups: groups)
        let options = PageEngineOptions(chromiumAgentChat: true, sharesWebKitProcess: true)
        let view = try #require(host.open(PageOpenRequest(descriptor: agent, root: agentRoot, routes: [], options: options)))
        defer { host.close(view) }
        #expect(view.engineDecision == .chromium)
        await view.chromiumStart?.value
        #expect(view.showsChromium)
        #expect(view.webKitPieces == nil)
        #expect(Self.webKitViews(in: view) == 0)
    }

    /// While the Chromium page is on its way, a script, a load, a reload and the host's WebKit hooks
    /// reach no engine and build none; the view itself holds the keyboard.
    @Test func callsWhileChromiumStartsBuildNoWebKitEngine() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        // The start task has not run yet: nothing has awaited since the open.
        #expect(view.chromiumSession == nil)
        view.evaluate("window.x = 1")
        view.open(route: "/b")
        view.reload()
        view.contextMenuEditor = { _ in }
        view.fileDrop = PageFileDrop(accepts: { _ in true }) { _ in }
        #expect(view.focusView === view)
        #expect(view.acceptsFirstResponder)
        #expect(view.lastUserEventUptime == nil)
        #expect(view.webKitPieces == nil)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        // The route asked for meanwhile is the one Chromium loads; the dropped script never ran.
        #expect(page.loaded == [descriptor.url(route: "#/b")])
        #expect(!page.evaluations.contains("window.x = 1"))
        #expect(!page.calls.contains { ($0.params["expression"] as? String) == "window.x = 1" })
        #expect(view.focusView === page.contentView)
        #expect(!view.acceptsFirstResponder)
        #expect(view.webKitPieces == nil)
    }

    /// A fallback builds the WebKit engine in its own turn, hands it what the host set while there
    /// was none, and gives it the keyboard the view held.
    @Test func aFallbackBuildsWebKitAndTakesTheHeldKeyboard() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.fails = true
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [], route: "#/c")))
        defer { host.close(view) }
        view.fileDrop = PageFileDrop(accepts: { _ in true }) { _ in }
        let window = PagePreloadPageTests.shownWindow()
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.focusPage()
        #expect(window.firstResponder === view)
        await view.chromiumStart?.value
        #expect(view.engineDecision == .webKit(.chromiumFailed))
        let engine = try #require(view.webKitPieces)
        #expect(view.webKitEngine === engine.view, "a host sees the WebKit engine once it shows the page")
        #expect(Self.webKitViews(in: view) == 1)
        #expect(!engine.view.isHidden)
        #expect(engine.view.url == descriptor.url(route: "#/c"))
        #expect(engine.view.fileDrop != nil, "the host's file drop reaches the WebKit view built later")
        #expect(window.firstResponder === engine.view)
        #expect(!view.acceptsFirstResponder)
    }

    /// A WebKit page builds its engine with the view, as before.
    @Test func aWebKitPageBuildsItsEngineAtOnce() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        #expect(engine.view.superview === view)
        #expect(!engine.view.isHidden)
        #expect(view.focusView === engine.view)
    }
}
