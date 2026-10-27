import AppKit
import CmuxNextDesign
import CmuxNextHibernation
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing
import WebKit

/// cmux's own pages hidden to WebKit (p14-energy-116, feature `ownPagesHiddenToWebKit`): while the
/// page's tab node is hidden below its window its WKWebView is hidden, so WebKit's page is hidden; it
/// shows again in the turn the node shows, with no reload. A miniaturized window and a hidden app stay
/// WebKit's own call. A page shown in Chromium builds no WebKit view for it.
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

    /// A window node, a workspace node and a tab node under them, the tab followed by `view` as a
    /// pane's tab follows it.
    private static func follow(_ view: PageWebView) -> (window: VisibilityNode, workspace: VisibilityNode, tab: VisibilityNode) {
        let window = VisibilityNode(root: "window", own: .visible)
        let workspace = VisibilityNode("workspace", own: .visible, parent: window)
        let tab = VisibilityNode("tab:page", own: .visible, parent: workspace)
        view.followAppearance(view.appearanceSignals, node: tab)
        return (window, workspace, tab)
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
        // A parked workspace hides its tabs too.
        nodes.workspace.set(.hidden)
        #expect(engine.view.isHidden)
        nodes.workspace.set(.visible)
        #expect(!engine.view.isHidden)
    }

    /// A miniaturized window and a hidden app are WebKit's own call: it already hides the page through
    /// its window. The host hides nothing there, so the WKWebView keeps the window's keyboard (hiding a
    /// first responder hands the keyboard to the next key view, and nothing gives it back). A tab
    /// parked while the window was miniaturized hides when the window shows.
    @Test func aMiniaturizedWindowOrHiddenAppLeavesTheViewAndItsKeyboardToWebKit() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let app = VisibilityNode(root: "app", own: .visible)
        let source = WindowVisibilitySource.of(window, app: app, read: { _ in .visible })
        let workspace = VisibilityNode("workspace", own: .visible, parent: source.node)
        let tab = VisibilityNode("tab:page", own: .visible, parent: workspace)
        window.contentView?.addSubview(view)
        view.followAppearance(view.appearanceSignals, node: tab)
        try #require(window.makeFirstResponder(engine.view))

        source.node.set(.hidden) // miniaturized
        #expect(tab.effective == .hidden)
        #expect(!engine.view.isHidden, "a miniaturized window is WebKit's call")
        #expect(window.firstResponder === engine.view)
        source.node.set(.visible)
        #expect(window.firstResponder === engine.view, "the keyboard is the page's again after the show")

        app.set(.hidden) // Cmd-H
        #expect(tab.effective == .hidden)
        #expect(!engine.view.isHidden, "a hidden app is WebKit's call")
        #expect(window.firstResponder === engine.view)
        app.set(.visible)
        #expect(window.firstResponder === engine.view)

        source.node.set(.hidden)
        tab.set(.hidden) // parked while the window is miniaturized: the tab's node does not flip
        source.node.set(.visible)
        #expect(engine.view.isHidden, "the window's show hides the parked tab's page")
        tab.set(.visible)
        #expect(!engine.view.isHidden)
    }

    /// A page the page lifecycle holds as shown keeps showing to WebKit until the tab's conceal has
    /// begun its hide picture (p13-webui-088: the picture is taken before the engine is told the page is
    /// hidden), then hides in that turn; the picture is of the page as it showed.
    @Test(.timeLimit(.minutes(1)))
    func aLifecyclePageHidesAfterItsHidePicture() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let engine = try #require(view.webKitPieces)
        #if DEBUG || CMUX_BENCH_HOOKS
        PageWebView.keepRenderingWhenCovered(engine.view)
        #endif
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        window.contentView?.addSubview(view)
        let painted: Bool? = await PageTestWait.value("paint") { done in view.whenPainted { done(true) } }
        try #require(painted == true)
        let rig = LifecycleDeadlineRig()
        let lifecycle = PageLifecycle(deadlines: rig.scheduler)
        let target = PageWebViewLifecycle(view, encoder: PageSnapshotEncoder(start: { _, done in done(nil) }))
        let nodes = Self.follow(view)
        lifecycle.show("page", page: target) // the tab's reveal

        nodes.tab.set(.hidden) // PaneController.selectTabNode: the node flips before the conceal
        #expect(!engine.view.isHidden, "the hide waits for the lifecycle's picture")
        #expect(!view.webKitHiddenByHost)
        lifecycle.hide("page", page: target) // the tab's conceal, a frame later
        #expect(view.hideState.picture == .capturing, "the hide asked WebKit for its picture")
        #expect(engine.view.isHidden, "hidden in the conceal's turn, after the picture began")
        let frame = await view.hideFrame()
        #expect(frame != nil, "WebKit gave no frame of the page as it showed")

        nodes.tab.set(.visible)
        #expect(!engine.view.isHidden)
        lifecycle.show("page", page: target)
        // The conceal comes first this time: the node's hide follows its picture at once.
        lifecycle.hide("page", page: target)
        #expect(!engine.view.isHidden)
        nodes.tab.set(.hidden)
        #expect(engine.view.isHidden)
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

    /// A page that plays sound or uses the camera or microphone stays visible to WebKit while its tab
    /// is hidden: the engine's media watch holds what WebKit reports (``PageWebKitMediaWatch``), and
    /// the page hides in the turn the sound and capture end.
    @Test func aPageThatPlaysSoundStaysVisibleToWebKitUntilTheSoundEnds() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let host = makeHost(Self.webKitHosting())
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        defer { host.close(view) }
        let engine = try #require(view.webKitPieces)
        #expect(engine.media != nil, "the engine watches its view's sound and capture")
        #expect(engine.media?.held == [], "a page that plays nothing holds nothing")
        var playing: Set<PageKeepReasons.KeepReason> = []
        let watch = PageWebKitMediaWatch(view: engine.view, keepReasons: view.keepReasons) { _ in playing }
        let nodes = Self.follow(view)
        nodes.tab.set(.hidden)
        #expect(engine.view.isHidden)

        playing = [.audible]
        Self.notify(engine.view, PageWebKitMediaWatch.captureKeys[0]) // WebKit's KVO notice
        #expect(view.keepReasons.current.contains(.audible))
        #expect(!engine.view.isHidden, "a page with sound stays visible to WebKit")
        playing = [.capture]
        Self.notify(engine.view, PageWebKitMediaWatch.captureKeys[1])
        #expect(!view.keepReasons.current.contains(.audible))
        #expect(!engine.view.isHidden, "a camera or microphone keeps it visible")
        playing = []
        Self.notify(engine.view, PageWebKitMediaWatch.captureKeys[1])
        #expect(view.keepReasons.current.isDisjoint(with: [.audible, .capture]))
        #expect(engine.view.isHidden, "hidden in the turn the sound and capture end")
        withExtendedLifetime(watch) {}
    }

    /// Posts the KVO notice of `key` on `view`, as WebKit does when its media state changes.
    private static func notify(_ view: WKWebView, _ key: String) {
        view.willChangeValue(forKey: key)
        view.didChangeValue(forKey: key)
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
        try await reportsHiddenWhileItsTabIsHidden(descriptor, root: root)
    }

    /// Live: the agent chat's page reports `hidden` to its script while its tab is hidden and
    /// `visible` after the show, with no reload.
    @Test(.timeLimit(.minutes(1)))
    func aHiddenAgentPanePageReportsHiddenAndShowsWithoutReload() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = try #require(PageWebKitAbsenceTests.agentRoot)
        try await reportsHiddenWhileItsTabIsHidden(agent, root: agentRoot)
    }

    /// Opens `descriptor` in WebKit in a shown window, hides its tab node and shows it again, reading
    /// `document.visibilityState` each time; the show reloads nothing.
    private func reportsHiddenWhileItsTabIsHidden(_ descriptor: PageDescriptor, root: URL) async throws {
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
