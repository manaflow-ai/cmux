import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing
import WebKit

/// cmux's own pages hidden to WebKit (p14-energy-116, feature `ownPagesHiddenToWebKit`): while the
/// page's tab node is hidden its WKWebView is hidden, so WebKit's page is hidden; it shows again in
/// the turn the node shows, with no reload. A page shown in Chromium builds no WebKit view for it.
@MainActor
@Suite(.serialized)
struct PageHiddenTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.page-hidden", resource: "page-hidden", processGroup: .solo, namespaces: [])
    /// The agent page as the page host knows it (`PageDescriptor.agent` lives in CmuxNextAgentPane).
    private let agent = PageDescriptor(id: "cmux.agent", resource: "agent-pane", processGroup: .agent, namespaces: ["cmux.agent."])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-hidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// The page host with the feature on (`hides`), over a Chromium host that prefers `engine`.
    private func makeHost(_ hosting: FakeChromiumHosting, hides: Bool = true) -> WebUIHost {
        WebUIHost(chromium: hosting, openPanel: nil, memory: QuietMemoryRegistry(), clock: PageTestClock.never,
                  hidesHiddenPagesFromWebKit: hides)
    }

    private static func webKitHosting() -> FakeChromiumHosting {
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        return hosting
    }

    /// A window node and a tab node under it, the tab followed by `view` as a pane's tab follows it.
    private static func follow(_ view: PageWebView) -> (window: VisibilityNode, tab: VisibilityNode) {
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab:page", own: .visible, parent: window)
        view.followAppearance(view.appearanceSignals, node: tab)
        return (window, tab)
    }

    @Test func aHiddenTabHidesItsWebKitViewAndShowsItInTheSameTurn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        let nodes = Self.follow(view)
        #expect(!engine.view.isHidden)
        nodes.tab.set(.hidden)
        #expect(engine.view.isHidden)
        #expect(view.webKitHiddenByHost)
        nodes.tab.set(.visible)
        #expect(!engine.view.isHidden, "shown in the node's turn")
        #expect(view.webKitPieces === engine, "the same view and document: nothing is rebuilt")
        // A miniaturized window hides its tabs too.
        nodes.window.set(.hidden)
        #expect(engine.view.isHidden)
        nodes.window.set(.visible)
        #expect(!engine.view.isHidden)
    }

    /// The agent chat in WebKit (the agent pane forwards its tab node to its page) is hidden the same way.
    @Test func aHiddenAgentPanePageIsHiddenToWebKit() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = try #require(PageWebKitAbsenceTests.agentRoot)
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: agent, root: agentRoot, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        let nodes = Self.follow(view)
        nodes.tab.set(.hidden)
        #expect(engine.view.isHidden)
        nodes.tab.set(.visible)
        #expect(!engine.view.isHidden)
    }

    /// An occluded window is WebKit's own call (its occlusion detection): the host hides nothing.
    @Test func anOccludedWindowIsLeftToWebKit() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        let nodes = Self.follow(view)
        nodes.window.set(.occluded)
        #expect(!engine.view.isHidden)
        #expect(!view.webKitHiddenByHost)
    }

    /// A capture of the hidden tab (Chrome's capturer count) keeps it visible to WebKit, so the
    /// capture sees a live page; the hide comes back with the last vote's release.
    @Test func aCapturedHiddenTabStaysVisibleToWebKit() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        let nodes = Self.follow(view)
        nodes.tab.set(.hidden)
        #expect(engine.view.isHidden)
        let vote = nodes.tab.captureVote(reason: "test.screenshot", stayHidden: true)
        #expect(!engine.view.isHidden)
        vote.release()
        #expect(engine.view.isHidden)
    }

    /// A page that captures media stays visible to WebKit while it does (Memory Saver's rule).
    @Test func aCapturingPageStaysVisibleToWebKit() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        let nodes = Self.follow(view)
        view.keepReasons.begin(.capture)
        nodes.tab.set(.hidden)
        #expect(!engine.view.isHidden)
        view.keepReasons.end(.capture)
        #expect(engine.view.isHidden, "the capture's end hides it in its turn")
    }

    /// With the feature off the host leaves the WebKit view alone; turning it on applies the node now,
    /// and off shows the view again.
    @Test func theFeatureSwitchDecides() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting(), hides: false)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        let nodes = Self.follow(view)
        nodes.tab.set(.hidden)
        #expect(!engine.view.isHidden)
        view.hidesWebKitWhenHostHidden = true
        #expect(engine.view.isHidden)
        view.hidesWebKitWhenHostHidden = false
        #expect(!engine.view.isHidden)
    }

    /// The lifecycle's freeze and the host's hide share the view: a thaw while the tab is hidden keeps
    /// it hidden, and a show while the page is frozen leaves it to the thaw.
    @Test func aFreezeAndAHostHideShareTheView() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        let nodes = Self.follow(view)
        nodes.tab.set(.hidden)
        #expect(view.freezePage())
        view.thawPage()
        #expect(engine.view.isHidden, "the thaw of a page whose tab is hidden keeps it hidden to WebKit")
        #expect(view.freezePage())
        nodes.tab.set(.visible)
        #expect(engine.view.isHidden, "still frozen: the show leaves it to the thaw")
        view.thawPage()
        #expect(!engine.view.isHidden)
    }

    /// A page shown in Chromium builds no WKWebView while its tab hides and shows.
    @Test func aChromiumPageBuildsNoWebKitViewWhileItsTabHidesAndShows() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let nodes = Self.follow(view)
        nodes.tab.set(.hidden)
        await view.chromiumStart?.value
        #expect(view.showsChromium)
        nodes.tab.set(.visible)
        nodes.tab.set(.hidden)
        #expect(view.webKitPieces == nil)
        #expect(PageWebKitAbsenceTests.webKitViews(in: view) == 0)
    }

    /// A fallback to WebKit while the tab is hidden builds its view hidden; the tab's show shows it.
    @Test func aFallbackWhileTheTabIsHiddenBuildsAHiddenView() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.fails = true
        let host = makeHost(hosting)
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let nodes = Self.follow(view)
        nodes.tab.set(.hidden)
        await view.chromiumStart?.value
        let engine = try #require(view.webKitPieces)
        #expect(engine.view.isHidden)
        nodes.tab.set(.visible)
        #expect(!engine.view.isHidden)
    }

    /// Live: the page itself reports `hidden` while its tab is hidden and `visible` after the show,
    /// and the show loads nothing again.
    @Test(.timeLimit(.minutes(1)))
    func aHiddenTabsPageReportsHiddenAndShowsWithoutReload() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let engine = try #require(view.webKitPieces)
        #if DEBUG || CMUX_BENCH_HOOKS
        // The test window is off screen; WebKit's occlusion check would call the shown page hidden.
        PageWebView.keepRenderingWhenCovered(engine.view)
        #endif
        window.contentView?.addSubview(view)
        await view.waitUntilLoaded()
        var loads = 0
        view.onLoaded = { loads += 1 }
        let nodes = Self.follow(view)
        let shown = try await Self.visibility(engine.view, becomes: "visible")
        #expect(shown == "visible")
        nodes.tab.set(.hidden)
        let hidden = try await Self.visibility(engine.view, becomes: "hidden")
        #expect(hidden == "hidden")
        nodes.tab.set(.visible)
        let shownAgain = try await Self.visibility(engine.view, becomes: "visible")
        #expect(shownAgain == "visible")
        #expect(loads == 0, "the show reloads nothing")
    }

    /// `document.visibilityState` once it is `state` (WebKit sends the change to the page after the turn).
    private static func visibility(_ view: WKWebView, becomes state: String) async throws -> String? {
        let script = """
        await new Promise(done => {
          if (document.visibilityState === state) return done();
          const check = () => {
            if (document.visibilityState !== state) return;
            document.removeEventListener('visibilitychange', check);
            done();
          };
          document.addEventListener('visibilitychange', check);
        });
        return document.visibilityState;
        """
        return try await view.callAsyncJavaScript(script, arguments: ["state": state], in: nil, contentWorld: .page) as? String
    }
}
