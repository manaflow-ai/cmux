import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// A ``PageWebView`` in Chromium mode, with a fake Chromium host: it sets the page up, loads the
/// document there, takes the page's messages, and falls back to WebKit when Chromium fails.
@MainActor
struct PageWebViewChromiumTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.chromium-page", resource: "chromium-page", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-chromium-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeView(_ hosting: FakeChromiumHosting) throws -> PageWebView {
        try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/start", chromium: hosting))
    }

    @Test func thePageShowsInChromiumAfterItsSetup() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        #expect(view.engineDecision == .chromium)
        let start = try #require(view.chromiumStart)
        await start.value
        let page = try #require(hosting.made.first)
        #expect(Array(page.calls.prefix(3).map(\.method)) == ["Page.enable", "Runtime.enable", "Runtime.addBinding"])
        #expect(page.calls.contains { $0.method == "Page.addScriptToEvaluateOnNewDocument" &&
            ($0.params["source"] as? String)?.contains(PageChromiumDocumentScripts.navigationScript) == true })
        #expect(page.loaded == [descriptor.url(route: "#/start")])
        #expect(view.focusView === page.contentView)
        #expect(page.contentView.superview === view)
        #expect(view.webKitPieces == nil)
        #expect(PageWebKitAbsenceTests.webKitViews(in: view) == 0)
        #expect(view.chromiumSession != nil)

        // The paint probe's message reaches the host through the binding.
        let painted: Bool? = await PageTestWait.value("paint") { done in
            view.whenPainted { done(true) }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": PagePaintProbe.handlerName, "body": 5])))
        }
        #expect(painted == true)
        #expect(view.chromiumSession?.deadline.isScheduled == false)

        // Loading ends with the document's load event; the page then gets its theme.
        page.onEvent?(.devTools(#"{"method":"Page.frameNavigated","params":{"frame":{"id":"A","url":"\#(descriptor.url().absoluteString)"}}}"#))
        page.onEvent?(.devTools(#"{"method":"Page.loadEventFired","params":{"timestamp":1}}"#))
        #expect(view.loaded)
        view.close()
        #expect(page.closed)
    }

    /// A route asked for before the Chromium page exists (the composer's Open Cloud… opens a new
    /// Cloud tab at `#/get`) is the one the page loads, not the route the view was made with.
    @Test func aRouteOpenedBeforeChromiumStartsIsTheOneItLoads() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        view.open(route: "/get")
        let start = try #require(view.chromiumStart)
        await start.value
        let page = try #require(hosting.made.first)
        #expect(page.loaded == [descriptor.url(route: "#/get")])
        view.close()
    }

    @Test func aPageThatNeverReachesTheHostReopensInWebKit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        let rig = LifecycleDeadlineRig()
        view.chromiumDeadlines = rig.scheduler
        let start = try #require(view.chromiumStart)
        await start.value
        // The page sent nothing: its fallback is armed as visible work (a person waits on the page), and nothing ends
        // the page before it runs out.
        let deadline = try #require(view.chromiumSession?.deadline)
        #expect(deadline.isScheduled)
        #expect(deadline.workClass == .visible)
        #expect(hosting.made.first?.closed != true)
        // Its wake posts the fallback, and the frame runs it: the page closes and the view reopens in WebKit.
        rig.fire()
        #expect(view.engineDecision == .webKit(.chromiumFailed))
        #expect(hosting.made.first?.closed == true)
        #expect(view.chromiumSession == nil)
        let engine = try #require(view.webKitPieces)
        #expect(!engine.view.isHidden)
        #expect(engine.view.superview === view)
        #expect(view.focusView === engine.view)
    }

    @Test func aChromiumThatCannotMakeThePageFallsBackAtOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.fails = true
        let view = try makeView(hosting)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(view.engineDecision == .webKit(.chromiumFailed))
        let engine = try #require(view.webKitPieces)
        #expect(!engine.view.isHidden)
        // The fallback loads the route in WebKit in the turn it happens.
        #expect(engine.view.url == descriptor.url(route: "#/start"))
    }

    @Test func theWebKitChoiceNeverStartsChromium() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.preference = .webkit
        let view = try makeView(hosting)
        #expect(view.engineDecision == .webKit(.personChoseWebKit))
        #expect(view.chromiumStart == nil)
        #expect(hosting.made.isEmpty)
        view.close()
    }

    @Test func aLinkToAnotherOriginOpensOutsideThePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        let opened: URL? = await PageTestWait.value("open") { done in
            view.onOpenExternal = { done($0) }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall([
                "name": PageChromiumDocumentScripts.navigateHandler,
                "body": ["url": "https://example.com/a", "command": true],
            ])))
        }
        #expect(opened == URL(string: "https://example.com/a"))
        #expect(view.externalLinkModifiers.contains(.command))
        #expect(page.loaded.count == 1)
        view.close()
    }

    /// A Chromium page asks the host for its dynamic paths, as the WebKit scheme handler does: the
    /// page's source answers a path under one of its prefixes; anything else is a 404 that never
    /// reaches the source.
    @Test func aChromiumPageGetsItsDynamicPathsFromTheHost() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dynamic = PageDescriptor(id: "test.chromium-dynamic", resource: "chromium-page", processGroup: .solo, namespaces: [], dynamicPrefixes: ["asset"])
        let hosting = FakeChromiumHosting()
        let source = OneResource()
        let view = try #require(PageWebView(descriptor: dynamic, root: root, routes: [], dynamicResources: source, chromium: hosting))
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        #expect(view.engineDecision == .chromium)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        let resources = try #require(page.resources)
        let png = await resources(try #require(URL(string: "cmux-page://test.chromium-dynamic/asset/a.png")))
        #expect(png == PageChromiumResponse(status: 200, mimeType: "image/png", body: Data([1, 2, 3])))
        let typeFromName = await resources(try #require(URL(string: "cmux-page://test.chromium-dynamic/asset/b.json")))
        #expect(typeFromName == PageChromiumResponse(status: 200, mimeType: "application/json", body: Data("{}".utf8)))
        #expect(await resources(try #require(URL(string: "cmux-page://test.chromium-dynamic/asset/none.png"))).status == 404)
        #expect(await resources(try #require(URL(string: "cmux-page://test.chromium-dynamic/index.html"))).status == 404)
        #expect(await resources(try #require(URL(string: "cmux-page://other.page/asset/a.png"))).status == 404)
        #expect(source.asked.map(\.path) == [["a.png"], ["b.json"], ["none.png"]])
        view.close()
    }
}

extension PageWebViewChromiumTests {
    /// A file dragged in from outside onto a Chromium page goes to the host's ``PageWebView/fileDrop``
    /// as it does on the WebKit page: the shim names the drag's files, the host tells the page to
    /// hand the drop over, and the page's drop message opens the first file once.
    @Test func aFileDraggedInFromOutsideOpensInTheHostWhenDropped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        var opened: [URL] = []
        view.fileDrop = PageFileDrop(accepts: { $0.pathExtension == "png" }) { opened.append($0) }
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        let image = URL(fileURLWithPath: "/tmp/a.png")
        let drop = FakeChromiumPage.bindingCall(["name": PageChromiumDocumentScripts.hostDropHandler, "body": [String: String]()])

        let told: Bool? = await PageTestWait.value("host drop on") { done in
            page.onCall = { if Self.hostDrop(in: page) == true { done(true) } }
            page.onEvent?(.filesDragged([image, URL(fileURLWithPath: "/tmp/b.png")]))
        }
        #expect(told == true)
        let first: URL? = await PageTestWait.value("drop") { done in
            view.fileDrop = PageFileDrop(accepts: { $0.pathExtension == "png" }) { opened.append($0); done($0) }
            page.onEvent?(.devTools(drop))
        }
        #expect(first == image)
        // The same drag drops once: a second message (page script can send one) opens nothing.
        page.onEvent?(.devTools(drop))
        await Self.barrier(view, page)
        #expect(opened == [image])

        // A drag the host does not take tells the page to keep it, and its drop message opens nothing.
        let off: Bool? = await PageTestWait.value("host drop off") { done in
            page.onCall = { if Self.hostDrop(in: page) == false { done(true) } }
            page.onEvent?(.filesDragged([URL(fileURLWithPath: "/tmp/a.txt")]))
        }
        #expect(off == true)
        page.onEvent?(.devTools(drop))
        await Self.barrier(view, page)
        #expect(opened == [image])
        view.close()
    }

    /// Returns once the page's messages sent so far reached the host: they are handled in order, so
    /// a link click sent last opens after them.
    private static func barrier(_ view: PageWebView, _ page: FakeChromiumPage) async {
        let opened: URL? = await PageTestWait.value("barrier") { done in
            view.onOpenExternal = { done($0) }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall([
                "name": PageChromiumDocumentScripts.navigateHandler, "body": ["url": "https://example.com/barrier"],
            ])))
        }
        view.onOpenExternal = nil
        #expect(opened == URL(string: "https://example.com/barrier"))
    }

    /// The last `__cmuxHostDrop(...)` value the host evaluated in `page`, nil when none.
    private static func hostDrop(in page: FakeChromiumPage) -> Bool? {
        let scripts = page.calls.filter { $0.method == "Runtime.evaluate" }.compactMap { $0.params["expression"] as? String }
        guard let last = scripts.last(where: { $0.contains("__cmuxHostDrop") }) else { return nil }
        return last.contains("(true)")
    }
}

extension PageWebViewChromiumTests {
    /// A real key or mouse event in the Chromium page backs the page's calls as the person's gesture,
    /// as one in the WebKit view does.
    @Test func aKeyOrClickInTheChromiumPageIsTheUsersGesture() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(view.router.userGestureEvent?() == nil)
        let uptime = ProcessInfo.processInfo.systemUptime
        page.onEvent?(.userInput(uptime))
        #expect(view.lastUserEventUptime == uptime)
        #expect(view.router.userGestureEvent?() == uptime)
        view.close()
    }

    /// A right-click in the Chromium page shows the host's menu, built as on the WebKit page: Copy on
    /// a selection, then the host's own rows (``PageWebView/contextMenuEditor``). Chromium hears
    /// the menu closed once, also when nothing is shown.
    @Test func aRightClickInTheChromiumPageShowsTheHostsMenu() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        var shown: [[String]] = []
        view.chromiumMenuPresenter = { menu, _, _ in shown.append(menu.items.map(\.title)) }
        var finished = 0

        // The desktop default: Copy on a selection.
        page.onEvent?(.contextMenu(PageChromiumContextMenu(location: CGPoint(x: 4, y: 5), selection: "hello", isEditable: false) {
            finished += 1
        }))
        #expect(shown == [[PageWebView.copyTitle]])
        #expect(finished == 1)

        // Nothing selected and no rows: no menu, and Chromium still hears it closed.
        page.onEvent?(.contextMenu(PageChromiumContextMenu(location: .zero, selection: "", isEditable: false) { finished += 1 }))
        #expect(shown.count == 1)
        #expect(finished == 2)

        // A host's editor gets the menu with Copy in it and adds its rows.
        view.contextMenuEditor = { menu in
            PageWebView.keepDefaultMenuItems(in: menu)
            menu.addItem(PageWebView.menuItem("Quote") {})
        }
        page.onEvent?(.contextMenu(PageChromiumContextMenu(location: .zero, selection: "hello", isEditable: false) { finished += 1 }))
        #expect(shown.last == [PageWebView.copyTitle, "Quote"])
        #expect(finished == 3)
        view.close()
    }
}

extension PageWebViewChromiumTests {
    /// A page function runs in the Chromium page as it runs in WebKit: an async function of the
    /// named arguments, its promise awaited and its value returned by value.
    @Test func aPageFunctionRunsInTheChromiumPage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        _ = await view.callPageFunction("return text + selector;", arguments: ["text": "a\"b", "selector": NSNull()])
        let call = try #require(page.calls.last { $0.method == "Runtime.evaluate" })
        #expect(call.params["expression"] as? String == "(async function(selector, text) {\nreturn text + selector;\n}).apply(null, [null,\"a\\\"b\"])")
        #expect(call.params["awaitPromise"] as? Bool == true)
        #expect(call.params["returnByValue"] as? Bool == true)
        #expect(page.evaluations.last == call.params["expression"] as? String)
        view.close()
    }

    // MARK: The Chromium browser ended (fallback storm)

    /// Eight Chromium pages, the first in a window and the others hidden (no window), all showing
    /// in Chromium, and the window that shows the first.
    private func eightPages(_ hosting: FakeChromiumHosting) async throws -> (views: [PageWebView], window: NSWindow) {
        var views: [PageWebView] = []
        for _ in 0..<8 {
            let view = try makeView(hosting)
            view.chromiumDeadlines = LifecycleDeadlineRig.never
            await view.chromiumStart?.value
            views.append(view)
        }
        let window = pageWindow()
        window.contentView?.addSubview(views[0])
        #expect(views.allSatisfy { $0.showsChromium })
        return (views, window)
    }

    /// A window that shows the pages added to its content view.
    private func pageWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Eight Chromium pages still on their way, the first in `window`: their starts have not run yet.
    private func eightStartingPages(_ hosting: FakeChromiumHosting, in window: NSWindow) throws -> [PageWebView] {
        let views = try (0..<8).map { _ in try makeView(hosting) }
        views.forEach { $0.chromiumDeadlines = LifecycleDeadlineRig.never }
        window.contentView?.addSubview(views[0])
        return views
    }

    /// How many of `views` show in WebKit.
    private func onWebKit(_ views: [PageWebView]) -> Int {
        views.filter { $0.engineDecision.engine == .webKit }.count
    }

    /// How many of `views` built a WebKit engine (a WKWebView, and the WebKit process it starts).
    private func webKitEngines(_ views: [PageWebView]) -> Int {
        views.filter { $0.webKitPieces != nil }.count
    }

    /// Ends the browser under the first `count` pages: each asks the supervisor in the end's turn.
    private func endBrowser(_ hosting: FakeChromiumHosting, pages count: Int = 8) {
        for page in hosting.made.prefix(count) { page.onEvent?(.ended) }
        #expect(hosting.supervisorAsks == count)
    }

    /// The browser under eight pages ends: no page reopens in WebKit in that turn, before the
    /// helper-app supervisor could bring Chromium back. At base all eight reopened at once.
    @Test func aBrowserEndReopensNoPageInWebKitInItsTurn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (views, window) = try await eightPages(hosting)
        for page in hosting.made { page.onEvent?(.ended) }
        #expect(onWebKit(views) == 0)
        #expect(webKitEngines(views) == 0)
        views.forEach { $0.close() }
        window.close()
    }

    /// The fallback storm: eight pages, one shown, wait for the supervisor with no engine page and no
    /// WebKit engine; after its give-up only the shown page builds one, and a hidden page when it shows.
    @Test func afterTheSupervisorGivesUpOnlyTheShownPageReopensInWebKit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (views, window) = try await eightPages(hosting)
        endBrowser(hosting)
        // Waiting: every Chromium page closed, no page on WebKit, no new Chromium page.
        #expect(hosting.made.allSatisfy { $0.closed })
        #expect(views.allSatisfy { !$0.showsChromium && $0.chromiumRecovery != nil })
        #expect(webKitEngines(views) == 0)
        #expect(hosting.made.count == 8)

        hosting.finishSupervision(.gaveUp)
        #expect(onWebKit(views) == 1)
        #expect(webKitEngines(views) == 1)
        #expect(views[0].engineDecision == .webKit(.chromiumFailed))
        #expect(views[0].webKitPieces?.view.isHidden == false)
        #expect(views[0].chromiumRecovery == nil)
        #expect(views.dropFirst().allSatisfy { $0.chromiumRecovery != nil })

        // A hidden page reopens in WebKit when it shows.
        window.contentView?.addSubview(views[1])
        #expect(onWebKit(views) == 2)
        #expect(webKitEngines(views) == 2)
        #expect(views[1].chromiumRecovery == nil)
        #expect(hosting.made.count == 8)
        views.forEach { $0.close() }
        #expect(views.allSatisfy { $0.chromiumRecovery == nil })
        window.close()
    }

    /// The supervisor restarts Chromium: the shown page makes a new Chromium page at the route opened
    /// while it waited, a hidden one only when it shows, and none builds a WebKit engine.
    @Test func afterTheSupervisorRestartsChromiumTheShownPageReturnsToChromium() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (views, window) = try await eightPages(hosting)
        endBrowser(hosting)
        views[0].open(route: "/moved")
        hosting.finishSupervision(.restarted)
        await views[0].chromiumStart?.value
        #expect(hosting.made.count == 9)
        #expect(hosting.made.last?.loaded == [descriptor.url(route: "#/moved")])
        #expect(views[0].showsChromium)

        // In the window but hidden: it still waits; shown: a new Chromium page.
        views[2].isHidden = true
        window.contentView?.addSubview(views[2])
        #expect(hosting.made.count == 9)
        views[2].isHidden = false
        await views[2].chromiumStart?.value
        #expect(hosting.made.count == 10)
        #expect(views[2].showsChromium)
        #expect(webKitEngines(views) == 0)
        views.forEach { $0.close() }
        window.close()
    }

    /// A page that closes while it waits for the supervisor does nothing on its answer.
    @Test func aPageClosedWhileItWaitsDoesNothingOnTheAnswer() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (views, window) = try await eightPages(hosting)
        endBrowser(hosting, pages: 1)
        let recovery = try #require(views[0].chromiumRecovery)
        views[0].close()
        #expect(views[0].chromiumRecovery == nil)
        hosting.finishSupervision(.gaveUp)
        withExtendedLifetime(recovery) {}
        #expect(views[0].engineDecision == .chromium)
        #expect(views[0].webKitPieces == nil)
        views.dropFirst().forEach { $0.close() }
        window.close()
    }

    /// The Chromium Host ends while it makes the browsers of eight pages, one shown: every page waits
    /// for the supervisor with no WebKit engine, and after its give-up only the shown page builds one.
    /// Before the fix each failed `makePage` reopened its page in WebKit at once, hidden pages too.
    @Test func aBrowserEndWhileThePagesAreMadeWaitsForTheSupervisor() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.holdsBrowsers = true
        let window = pageWindow()
        let views = try eightStartingPages(hosting, in: window)
        let starts = views.compactMap(\.chromiumStart)
        #expect(starts.count == 8)
        let held: Bool? = await PageTestWait.value("eight browsers held") { done in
            hosting.onBrowserHeld = { [unowned hosting] in if hosting.heldBrowsers == 8 { done(true) } }
        }
        #expect(held == true)
        hosting.onBrowserHeld = nil

        hosting.endHeldBrowsers()
        for start in starts { await start.value }
        #expect(hosting.supervisorAsks == 8)
        #expect(hosting.made.isEmpty)
        #expect(views.allSatisfy { $0.chromiumRecovery != nil && $0.chromiumStart == nil })
        #expect(onWebKit(views) == 0)
        #expect(webKitEngines(views) == 0)

        hosting.finishSupervision(.gaveUp)
        #expect(webKitEngines(views) == 1)
        #expect(views[0].engineDecision == .webKit(.chromiumFailed))
        window.contentView?.addSubview(views[1])
        #expect(webKitEngines(views) == 2)
        #expect(hosting.made.isEmpty)
        views.forEach { $0.close() }
        window.close()
    }

    /// The browser ends during the setup of eight pages, one shown, whether the page hears the end
    /// first (``PageChromiumEvent/ended`` before its setup call fails) or only its setup call's typed
    /// failure: every page waits for the supervisor, and after its give-up only the shown page builds
    /// a WebKit engine. Before the fix the end went unheard before the session, and the failed setup
    /// call reopened every page in WebKit at once.
    @Test(arguments: [true, false])
    func aBrowserEndDuringThePagesSetupWaitsForTheSupervisor(hearsEnded: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.onMade = { page in
            page.answer = { [unowned page] _, _ in
                guard page.devToolsFailure == nil else { return nil }
                if hearsEnded { page.onEvent?(.ended) }
                page.devToolsFailure = hearsEnded ? HostGone() as any Error : PageChromiumStartError.browserEnded
                return nil
            }
        }
        let window = pageWindow()
        let views = try eightStartingPages(hosting, in: window)
        for start in views.compactMap(\.chromiumStart) { await start.value }

        #expect(hosting.made.count == 8)
        #expect(hosting.made.allSatisfy { $0.closed })
        #expect(hosting.supervisorAsks == 8)
        #expect(views.allSatisfy { !$0.showsChromium && $0.chromiumRecovery != nil })
        #expect(onWebKit(views) == 0)
        #expect(webKitEngines(views) == 0)

        hosting.finishSupervision(.gaveUp)
        #expect(webKitEngines(views) == 1)
        #expect(views[0].engineDecision == .webKit(.chromiumFailed))
        #expect(hosting.made.count == 8)
        views.forEach { $0.close() }
        window.close()
    }

    /// A hidden page whose browser ended is discarded while it waits; after the give-up it shows:
    /// it reopens in WebKit and makes no new Chromium page, whether its restore comes before it is in
    /// the window or after. Before the fix the discard dropped the wait and the restore started Chromium.
    @Test func aPageDiscardedWhileItWaitsShowsInWebKitAfterTheGiveUp() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (views, window) = try await eightPages(hosting)
        endBrowser(hosting)
        let decoder = PageSnapshotEncoder(start: { _, done in done(nil) }, decode: { _, done in done(nil) })
        #expect(views[1].discardPage(decoder: decoder))
        #expect(views[2].discardPage(decoder: decoder))
        #expect(views[1].isDiscarded && views[1].chromiumRecovery != nil)
        #expect(views[2].isDiscarded && views[2].chromiumRecovery != nil)

        hosting.finishSupervision(.gaveUp)
        #expect(views[1].webKitPieces == nil)
        #expect(views[2].webKitPieces == nil)

        // In the window, then the lifecycle's restore.
        window.contentView?.addSubview(views[1])
        #expect(views[1].webKitPieces == nil, "a discarded page built an engine before its restore")
        views[1].restoreDiscardedPage()
        // The restore, then in the window.
        views[2].restoreDiscardedPage()
        #expect(views[2].webKitPieces == nil, "a hidden page built an engine")
        window.contentView?.addSubview(views[2])

        for view in views[1...2] {
            #expect(!view.isDiscarded)
            #expect(view.engineDecision == .webKit(.chromiumFailed))
            #expect(view.webKitPieces?.view.isHidden == false)
            #expect(view.chromiumStart == nil)
            #expect(view.chromiumRecovery == nil)
        }
        #expect(hosting.made.count == 8)
        views.forEach { $0.close() }
        window.close()
    }

    /// A discarded page that waits is restored before the supervisor answers: it starts no Chromium
    /// page while the host restarts, and one once the supervisor brought Chromium back.
    @Test func aDiscardedPageRestoredBeforeTheAnswerStartsChromiumOnlyAfterTheRestart() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (views, window) = try await eightPages(hosting)
        endBrowser(hosting, pages: 2)
        let decoder = PageSnapshotEncoder(start: { _, done in done(nil) }, decode: { _, done in done(nil) })
        #expect(views[1].discardPage(decoder: decoder))
        window.contentView?.addSubview(views[1])
        views[1].restoreDiscardedPage()
        #expect(views[1].chromiumStart == nil)
        #expect(views[1].chromiumRecovery != nil)
        #expect(hosting.made.count == 8)

        hosting.finishSupervision(.restarted)
        await views[0].chromiumStart?.value
        await views[1].chromiumStart?.value
        #expect(hosting.made.count == 10)
        #expect(views[1].showsChromium)
        #expect(webKitEngines(views) == 0)
        views.forEach { $0.close() }
        window.close()
    }
}

/// The "Page unresponsive" card of a Chromium page: a tab-scoped cmux dialog while the
/// renderer hangs and the page shows, answered through the page and never waited on.
extension PageWebViewChromiumTests {
    /// A page whose Chromium page attached, with no deadline.
    private func attachedPage(_ hosting: FakeChromiumHosting) async throws -> (PageWebView, FakeChromiumPage) {
        let view = try makeView(hosting)
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        await view.chromiumStart?.value
        return (view, try #require(hosting.made.first))
    }

    @Test func aShownPageThatHangsShowsTheCardAndWaitAnswersIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await attachedPage(hosting)
        view.setEngineVisible(true)
        page.onEvent?(.unresponsive)
        let record = try #require(hosting.dialogs.records.first)
        #expect(hosting.dialogs.records.count == 1)
        #expect(record.scope == "tab")
        #expect(record.spec.identifier == PageHangNotice.identifier)
        #expect(record.spec.cancelButton?.id == PageHangNotice.waitButton)
        #expect(hosting.dialogHost.shown.count == 1)
        #expect(page.hangAnswers.isEmpty)

        #expect(hosting.dialogs.press(record.id, button: PageHangNotice.waitButton))
        #expect(page.hangAnswers == [false])
        #expect(hosting.dialogs.records.isEmpty)
        // Chromium reports the hang again while the renderer still hangs: the card comes back.
        page.onEvent?(.responsive)
        page.onEvent?(.unresponsive)
        #expect(hosting.dialogs.records.count == 1)
        view.close()
        #expect(hosting.dialogs.records.isEmpty)
        #expect(page.hangAnswers == [false])
    }

    @Test func exitEndsTheRendererAndTheCrashTakesOver() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await attachedPage(hosting)
        view.setEngineVisible(true)
        page.onEvent?(.unresponsive)
        let record = try #require(hosting.dialogs.records.first)
        #expect(hosting.dialogs.press(record.id, button: PageHangNotice.exitButton))
        #expect(page.hangAnswers == [true])
        #expect(hosting.dialogs.records.isEmpty)
        page.onEvent?(.crashed)
        #expect(hosting.dialogs.records.isEmpty)
        view.close()
    }

    @Test func aHiddenPageShowsTheCardOnlyWhenItShows() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await attachedPage(hosting)
        // No window: the page attached hidden.
        page.onEvent?(.unresponsive)
        #expect(hosting.dialogs.records.isEmpty)
        view.setEngineVisible(true)
        #expect(hosting.dialogs.records.count == 1)
        // Hidden again: the card goes, unanswered, and comes back with the page.
        view.setEngineVisible(false)
        #expect(hosting.dialogs.records.isEmpty)
        #expect(page.hangAnswers.isEmpty)
        view.setEngineVisible(true)
        #expect(hosting.dialogs.records.count == 1)
        view.close()
        #expect(page.hangAnswers.isEmpty)
    }

    @Test func aRendererThatAnswersAgainTakesTheCardDownUnanswered() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await attachedPage(hosting)
        view.setEngineVisible(true)
        page.onEvent?(.unresponsive)
        #expect(hosting.dialogs.records.count == 1)
        page.onEvent?(.responsive)
        #expect(hosting.dialogs.records.isEmpty)
        #expect(hosting.dialogHost.shown.isEmpty)
        #expect(page.hangAnswers.isEmpty)
        // A hidden page that hung and answered again shows nothing when it shows.
        view.setEngineVisible(false)
        page.onEvent?(.unresponsive)
        page.onEvent?(.responsive)
        view.setEngineVisible(true)
        #expect(hosting.dialogs.records.isEmpty)
        view.close()
    }

    @Test func aClosedTabEndsTheCardWithoutAnAnswer() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await attachedPage(hosting)
        view.setEngineVisible(true)
        page.onEvent?(.unresponsive)
        let dialog = try #require(hosting.dialogHost.shown.first)
        hosting.dialogHost.closeScope(of: dialog)
        #expect(hosting.dialogs.records.isEmpty)
        #expect(page.hangAnswers.isEmpty)
        view.close()
    }
}

/// The error a Chromium Host's end fails a page's pending DevTools call with (no typed end).
private struct HostGone: Error {}

/// A dynamic source with two resources: `a.png` (typed) and `b.json` (typed by its name).
@MainActor
private final class OneResource: PageDynamicResourceSource {
    private(set) var asked: [PageResourceRequest] = []

    func resource(for request: PageResourceRequest) async -> PageResource? {
        asked.append(request)
        switch request.path {
        case ["a.png"]: return PageResource(data: Data([1, 2, 3]), mimeType: "image/png")
        case ["b.json"]: return PageResource(data: Data("{}".utf8))
        default: return nil
        }
    }
}
