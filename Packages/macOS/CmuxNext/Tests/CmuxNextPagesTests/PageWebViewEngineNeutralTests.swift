import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// The calls a host makes on a page whichever engine shows it (``PageWebView`` in Chromium mode, with
/// a fake Chromium host): a picture, an extra message handler, and a right-click menu that waits for
/// the page's report.
@MainActor
struct PageWebViewEngineNeutralTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.engine-neutral", resource: "engine-neutral", processGroup: .solo, namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-neutral-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func started(_ hosting: FakeChromiumHosting, before: (PageWebView) -> Void = { _ in }) async throws -> (PageWebView, FakeChromiumPage) {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumDeadlines = LifecycleDeadlineRig.never
        before(view)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        #expect(view.showsChromium)
        return (view, page)
    }

    @Test func aPictureOfTheChromiumPageIsItsScreenshot() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await started(hosting)
        view.frame = NSRect(x: 0, y: 0, width: 4, height: 3)
        let image = NSImage(size: NSSize(width: 4, height: 3))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 3).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        page.answer = { method, _ in method == "Page.captureScreenshot" ? #"{"data":"\#(png.base64EncodedString())"}"# : nil }
        let snapshot = await view.snapshot()
        #expect(snapshot?.size == NSSize(width: 4, height: 3))
        view.close()
    }

    @Test func anExtraMessageHandlerHearsTheChromiumPage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        var heard: [String] = []
        let (view, page) = try await started(hosting) { view in
            view.addMessageHandler("testReport") { body in heard.append((body as? [String: Any])?["text"] as? String ?? "?") }
        }
        // The page script installs `window.webkit.messageHandlers.testReport`.
        #expect(page.calls.contains { $0.method == "Page.addScriptToEvaluateOnNewDocument" &&
            (($0.params["source"] as? String)?.contains("\"testReport\"") ?? false) })
        let got: String? = await PageTestWait.value("report") { done in
            view.addMessageHandler("testReport") { body in done((body as? [String: Any])?["text"] as? String ?? "?") }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": "testReport", "body": ["text": "hi"]])))
        }
        #expect(got == "hi")
        #expect(heard.isEmpty)
        view.close()
    }

    /// On the page channel the page script names its event, and a post after the page's commit
    /// reaches the handler in the event's turn, each message of a batched post in order, with no DevTools call.
    @Test func aPageChannelPostReachesTheHandlerWithNoDevToolsCall() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.onMade = { $0.pageHostEvent = "cmux-page-host-post" }
        var heard: [String] = []
        let (view, page) = try await started(hosting) { view in
            view.addMessageHandler("testReport") { body in heard.append((body as? [String: Any])?["text"] as? String ?? "?") }
        }
        #expect(page.calls.contains { $0.method == "Page.addScriptToEvaluateOnNewDocument" &&
            (($0.params["source"] as? String)?.contains(#"const channelEvent = "cmux-page-host-post";"#) ?? false) })
        page.onEvent?(.committed(descriptor.url(route: "")))
        let before = page.calls.count
        page.onEvent?(.pageHostPost(#"[{"name":"testReport","body":{"text":"a"}},{"name":"testReport","body":{"text":"b"}}]"#,
                                    sender: descriptor.url(route: "")))
        #expect(heard == ["a", "b"], "the post's messages reach the handler in its turn")
        #expect(page.calls.count == before, "a DevTools call for the post: \(page.calls.dropFirst(before).map(\.method))")
        view.close()
    }

    /// A new document's first-paint report that arrives before its commit is held, and delivered after the view
    /// reset for that commit: the page stays painted instead of the reset clearing the paint it already reported.
    @Test func aPaintReportBeforeItsCommitSurvivesTheCommit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.onMade = { $0.pageHostEvent = "cmux-page-host-post" }
        let (view, page) = try await started(hosting)
        let url = descriptor.url(route: "")
        page.onEvent?(.pageHostPost(#"{"name":"\#(PagePaintProbe.handlerName)","body":1}"#, sender: url))
        #expect(!view.hasPainted, "a post was judged before its document's commit")
        page.onEvent?(.committed(url))
        #expect(view.hasPainted, "the commit's reset cleared the paint its document reported before it")
        view.close()
    }

    /// The next-frame wait runs through the page's `evaluate`: on the renderer path (`tabEvaluate`)
    /// it makes no DevTools call, and the body runs once the page answers.
    @Test func theNextFrameWaitRunsThroughTheChromiumPagesEvaluate() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await started(hosting)
        page.rendererEvaluate = { _ in "null" }
        let ran: Bool? = await PageTestWait.value("frame") { done in
            view.afterNextFrame { done(true) }
        }
        #expect(ran == true)
        #expect(page.evaluations.last?.contains("requestAnimationFrame") == true)
        #expect(!page.calls.contains { $0.method == "Runtime.evaluate" &&
            (($0.params["expression"] as? String)?.contains("requestAnimationFrame") ?? false) })
        view.close()
    }

    /// A host whose menu depends on the page's report (the agent chat) builds it only after its wait.
    @Test func aRightClickMenuWaitsForTheHostsWait() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await started(hosting)
        var built = 0
        view.contextMenuEditor = { menu in
            built += 1
            menu.addItem(PageWebView.menuItem("Row \(built)") {})
        }
        var waitedBeforeBuilding = false
        view.chromiumMenuWait = { waitedBeforeBuilding = built == 0 }
        let shown: [String]? = await PageTestWait.value("menu") { done in
            view.chromiumMenuPresenter = { menu, _, _ in done(menu.items.map(\.title)) }
            page.onEvent?(.contextMenu(PageChromiumContextMenu(location: .zero, selection: "", isEditable: false) {}))
            // The menu waits first: nothing is built in the click's own turn.
            #expect(built == 0)
        }
        #expect(waitedBeforeBuilding)
        #expect(shown == ["Row 1"])
        view.close()
    }

    /// The WebKit engine is there for the WebKit-only tools only while it shows the page:
    /// nil while Chromium shows it.
    @Test func theWebKitEngineIsOfferedOnlyWhileWebKitShowsThePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, _) = try await started(FakeChromiumHosting())
        #expect(view.webKitEngine == nil)
        #expect(view.webKitPieces == nil)
        view.close()
        let webKit = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        #expect(webKit.webKitEngine === webKit.webView)
        webKit.close()
    }

    /// Ending a Chromium page's document loads nothing into its unused WebKit view: an empty load
    /// there starts a WebContent process for a page that never had one.
    @Test func endingAChromiumDocumentLoadsNothingIntoWebKit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started(FakeChromiumHosting())
        view.close()
        view.endPageDocument()
        #expect(page.closed)
        #expect(view.webKitPieces == nil, "ending a Chromium document built a WebKit view")
    }

    /// One zoom in both engines: points per CSS pixel, which the WebKit view shows too.
    @Test func thePageZoomIsTheOneBothEnginesShow() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: nil))
        view.additionalZoom = 1.5
        #expect(Double(view.webView.pageZoom) == view.pageZoom)
        view.close()
    }
}
