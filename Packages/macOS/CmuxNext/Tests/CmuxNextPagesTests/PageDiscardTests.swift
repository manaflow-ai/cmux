import AppKit
import CmuxNextHibernation
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import Testing
import WebKit

/// A page's discard and restore (plans/cmux-next/chrome-parity/p13-webui.md 3.C, task 030): the
/// discard makes no call into the page and ends its engine page and subscriptions in one turn, the
/// shell keeps route, snapshot and state, and the show draws the snapshot, makes the engine page
/// again from the same host and hands the new document its state before its first paint.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageDiscardTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.discard-page", resource: "discard-page", processGroup: .viewer,
                                            namespaces: ["test.discard."])
    private let provider = LiveSubscriptions()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-discard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func makeView(_ hosting: FakeChromiumHosting?) throws -> PageWebView {
        let view = try #require(PageWebView(descriptor: descriptor, root: root,
                                            routes: [PageRoute(prefix: "test.discard.", provider: provider)],
                                            route: "#/a", chromium: hosting))
        view.chromiumClock = PageTestClock.never
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        return view
    }

    private func subscribe(_ view: PageWebView) async {
        let reply = await view.router.handle(["t": "sub", "id": 1, "stream": "test.discard.changed"])
        #expect(reply["t"]?.stringValue == "ok")
    }

    /// The acceptance: a discarded shell holds no engine page and no subscription, and the discard
    /// made no call into the page (no DevTools call, no script), all before it returned.
    @Test func aDiscardEndsTheEnginePageAndSubscriptionsWithNoCallIntoThePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        defer { view.close() }
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        await subscribe(view)
        #expect(view.router.subscriptionCount == 1)
        #expect(provider.live == 1)
        let calls = page.calls.count, evaluations = page.evaluations.count

        #expect(view.discardPage())

        #expect(view.isDiscarded)
        #expect(view.chromiumPage == nil)
        #expect(page.closed)
        #expect(page.contentView.superview == nil)
        #expect(view.router.subscriptionCount == 0)
        #expect(provider.live == 0)
        #expect(page.calls.count == calls, "the discard called into the page")
        #expect(page.evaluations.count == evaluations, "the discard ran a script in the page")
        #expect(!view.loadState.isLoading, "a discarded page reads as loading and blocks its lifecycle")
        // The shell keeps its route; nothing loads until it shows.
        view.open(route: "/b")
        #expect(view.route == "#/b")
        #expect(hosting.made.count == 1)
        view.reload()
        #expect(hosting.made.count == 1)
    }

    @Test func aShownPageIsNotDiscarded() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try makeView(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        defer {
            view.close()
            view.removeFromSuperview()
        }
        #expect(!view.discardPage())
        #expect(!view.isDiscarded)
        #expect(view.webKitView.navigationDelegate === view)
    }

    /// 10 discard and restore cycles make one engine page per restore from the same host and close
    /// each before the next: one live engine page at the end, as at the start, loading the route the
    /// shell kept (the fake's count stands for `runtime.hosts`, which p13-webui-062 empties per close).
    @Test func tenDiscardAndRestoreCyclesLeaveOneLiveEnginePage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        defer { view.close() }
        await view.chromiumStart?.value
        for cycle in 0..<10 {
            if cycle == 4 { view.open(route: "/b") }
            #expect(view.discardPage())
            #expect(hosting.made.filter { !$0.closed }.isEmpty)
            view.restoreDiscardedPage()
            #expect(!view.isDiscarded)
            await view.chromiumStart?.value
            #expect(hosting.made.filter { !$0.closed }.count == 1)
        }
        #expect(hosting.made.count == 11)
        let last = try #require(hosting.made.last)
        #expect(view.chromiumPage === last)
        #expect(last.loaded == [descriptor.url(route: "#/b")])
    }

    /// The show draws the hide-time snapshot in its own turn, in a layer with no implicit actions;
    /// the new document gets the saved state from a document-start script; both go at its first paint.
    @Test func theRestoreDrawsTheSnapshotAndHandsTheStateToTheNewDocumentUntilItPaints() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try makeView(hosting)
        defer { view.close() }
        await view.chromiumStart?.value
        let image = try Self.image()
        view.keepForDiscard(snapshot: image, state: ["draft": "hello"])
        #expect(view.discardPage())

        view.restoreDiscardedPage()

        #expect(view.showsDiscardSnapshot)
        let cover = try #require(view.discardShell.cover)
        #expect(cover.superlayer === view.layer)
        #expect(cover.frame == view.bounds)
        #expect((cover.contents as AnyObject?) === image)
        for key in ["contents", "bounds", "position", "hidden", "onOrderIn", "onOrderOut"] {
            #expect(cover.actions?[key] is NSNull, "the snapshot layer animates \(key)")
        }
        #expect(view.loadState.isLoading)
        let scripts = view.webKitView.configuration.userContentController.userScripts.map(\.source)
        let restore = try #require(scripts.first { $0.contains(PageWebView.restoreGlobal) })
        #expect(restore.contains(#""draft":"hello""#))
        #expect(restore.contains(#""wasDiscarded":true"#))

        await view.chromiumStart?.value
        let page = try #require(hosting.made.last)
        #expect(page.calls.contains { $0.method == "Page.addScriptToEvaluateOnNewDocument"
            && ($0.params["source"] as? String)?.contains(PageWebView.restoreGlobal) == true },
                "the Chromium page got no restore script before its document")
        #expect(page.loaded == [descriptor.url(route: "#/a")])

        let painted: Bool? = await PageTestWait.value("paint") { done in
            view.whenPainted { done(true) }
            page.onEvent?(.devTools(FakeChromiumPage.bindingCall(["name": PagePaintProbe.handlerName, "body": 5])))
        }
        #expect(painted == true)
        #expect(!view.showsDiscardSnapshot)
        #expect(cover.superlayer == nil)
        #expect(!view.webKitView.configuration.userContentController.userScripts.contains { $0.source.contains(PageWebView.restoreGlobal) })
        #expect(view.discardShell.snapshot == nil)
        #expect(view.discardShell.state == nil)
    }

    /// A WebKit page leaves its document with no delegate, so nothing of it reaches the host, and
    /// comes back in the same view (its process group) with the delegate set again.
    @Test func aWebKitPageLeavesItsDocumentAndComesBackInTheSameView() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let view = try makeView(nil)
        defer { view.close() }
        let webView = view.webKitView
        #expect(view.discardPage())
        #expect(webView.navigationDelegate == nil)
        #expect(webView.isHidden)
        view.restoreDiscardedPage()
        #expect(view.webKitView === webView)
        #expect(webView.navigationDelegate === view)
        #expect(!webView.isHidden)
        #expect(!view.showsDiscardSnapshot, "no snapshot was kept, so none is drawn")
    }

    /// The restore script hands its state to the first document only: a later document of the same
    /// Chromium page (a reload after a crash) finds the token in session storage.
    @Test func theRestoreScriptRunsOncePerRestore() {
        let script = PageWebView.restoreScript(["wasDiscarded": true, "state": .null], token: "t1")
        #expect(script.contains(#"sessionStorage.getItem("cmux.page.restore.t1")"#))
        #expect(script.contains(#"window.__cmuxPageRestore = {"#))
    }

    /// Through the lifecycle: a discard-blocking keep reason keeps a page past its discard time; once
    /// it goes, the next pass discards the page, and its show brings it back.
    @Test func aKeepReasonBlocksTheDiscard() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = LifecycleDeadlineRig()
        let lifecycle = PageLifecycle(deadlines: rig.scheduler)
        let view = try makeView(nil)
        defer { view.close() }
        view.loaded = true
        let target = PageWebViewLifecycle(view)
        lifecycle.hide("tab", page: target)
        lifecycle.setKeepReasons([.userEdits], for: "tab")
        rig.advance(to: .seconds(900))
        lifecycle.runPass()
        #expect(lifecycle.state(of: "tab") != .discarded)
        #expect(!view.isDiscarded)

        lifecycle.setKeepReasons([], for: "tab")
        lifecycle.runPass()
        #expect(lifecycle.state(of: "tab") == .discarded)
        #expect(view.isDiscarded)

        lifecycle.show("tab", page: target)
        #expect(lifecycle.state(of: "tab") == .active)
        #expect(!view.isDiscarded)
    }

    private static func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        return try #require(context.makeImage())
    }
}

/// A provider whose streams count while they live: the router's cancel ends one.
@MainActor
private final class LiveSubscriptions: PageProvider {
    private(set) var live = 0

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .null }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        live += 1
        return PageSubscription(frozenDelivery: .resync) { [weak self] in self?.live -= 1 }
    }
}
