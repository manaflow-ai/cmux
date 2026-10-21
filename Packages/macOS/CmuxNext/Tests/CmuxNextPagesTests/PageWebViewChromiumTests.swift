@testable import CmuxNextPages
import Foundation
import Testing

/// A ``PageWebView`` in Chromium mode, with a fake Chromium host: it sets the page up, loads the
/// document there, takes the page's messages, and falls back to WebKit when Chromium fails.
@MainActor
struct PageWebViewChromiumTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.chromium-page", resource: "chromium-page", namespaces: [])

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
        view.chromiumClock = PageTestClock.never
        #expect(view.engineDecision == .chromium)
        let start = try #require(view.chromiumStart)
        await start.value
        let page = try #require(hosting.made.first)
        #expect(Array(page.calls.prefix(3).map(\.method)) == ["Page.enable", "Runtime.enable", "Runtime.addBinding"])
        #expect(page.calls.contains { $0.method == "Page.addScriptToEvaluateOnNewDocument" &&
            ($0.params["source"] as? String) == PageChromiumDocumentScripts.navigationScript })
        #expect(page.loaded == [descriptor.url(route: "#/start")])
        #expect(view.focusView === page.contentView)
        #expect(page.contentView.superview === view)
        #expect(view.webKitView.isHidden)
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
        view.chromiumClock = PageTestClock.never
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
        view.chromiumClock = PageTestClock.immediate
        // The deadline fires on its own; the page closes when the view falls back.
        let closed: Bool? = await PageTestWait.value("fallback") { done in
            hosting.onMade = { page in page.onClose = { done(true) } }
            #expect(view.chromiumStart != nil)
        }
        #expect(closed == true)
        #expect(view.engineDecision == .webKit(.chromiumFailed))
        #expect(hosting.made.first?.closed == true)
        #expect(view.chromiumSession == nil)
        #expect(!view.webKitView.isHidden)
        #expect(view.focusView === view.webKitView)
    }

    @Test func aChromiumThatCannotMakeThePageFallsBackAtOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.fails = true
        let view = try makeView(hosting)
        let start = try #require(view.chromiumStart)
        await start.value
        #expect(view.engineDecision == .webKit(.chromiumFailed))
        #expect(!view.webKitView.isHidden)
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
        view.chromiumClock = PageTestClock.never
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
        let dynamic = PageDescriptor(id: "test.chromium-dynamic", resource: "chromium-page", namespaces: [], dynamicPrefixes: ["asset"])
        let hosting = FakeChromiumHosting()
        let source = OneResource()
        let view = try #require(PageWebView(descriptor: dynamic, root: root, routes: [], dynamicResources: source, chromium: hosting))
        view.chromiumClock = PageTestClock.never
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
        view.chromiumClock = PageTestClock.never
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
