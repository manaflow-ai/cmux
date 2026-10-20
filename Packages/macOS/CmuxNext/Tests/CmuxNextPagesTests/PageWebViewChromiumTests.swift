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
}
