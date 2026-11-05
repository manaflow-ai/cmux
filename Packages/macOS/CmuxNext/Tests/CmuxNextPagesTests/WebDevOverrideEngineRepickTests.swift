import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing

/// A page open in Chromium when the live web loop turns on (`web-dev.json` names an overlay or a dev
/// server) and whose Chromium cannot serve the loop (``PageChromiumHosting/setLivePages(_:)`` false)
/// moves to WebKit at once, at the route and scroll it showed, instead of keeping its bundled files
/// until it next opens. An agent's loop on a NIGHTLY found Settings, opened before the overlay was
/// installed, never showing the applied change (cmuxterm-hq#7149 L8).
@MainActor
@Suite(.serialized, .closesItsWindows)
struct WebDevOverrideEngineRepickTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.live-repick", resource: "live-repick", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-live-repick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = "<!doctype html><title>Page</title><body style=\"margin:0\"><div style=\"height:5000px\"></div></body>"
        try Data(page.utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A page shown in Chromium, in a window, scrolled to `scrollY` (what its scroll capture answers).
    private func shownInChromium(_ hosting: FakeChromiumHosting, scrollY: Int) async throws -> (PageWebView, FakeChromiumPage, NSWindow) {
        hosting.onMade = { page in
            page.answer = { method, params in
                guard method == "Runtime.evaluate", (params["expression"] as? String)?.contains("scrollingElement") == true else { return nil }
                return #"{"result":{"type":"object","value":[{"path":null,"top":\#(scrollY),"left":0}]}}"#
            }
        }
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], route: "#/start", chromium: hosting))
        view.chromiumClock = PageTestClock.never
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        try #require(window.contentView).addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        try #require(view.chromiumPage != nil)
        return (view, page, window)
    }

    @Test(.timeLimit(.minutes(1))) func aChromiumPageMovesToWebKitAtItsRouteAndScrollWhenTheLoopTurnsOn() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page, window) = try await shownInChromium(hosting, scrollY: 1234)
        defer {
            window.closeAfterTest()
            view.close()
        }

        await WebDevOverrideWatcher.reloadPages(live: true, hosting: hosting, pages: [view], served: WebBundleServedViews(), watcher: WebDevOverrideWatcher())?.value

        #expect(view.chromiumPage == nil, "the page stayed in Chromium, which serves only its bundled files")
        #expect(page.closed)
        #expect(view.engineDecision == .webKit(.liveWebOverride))
        #expect(view.webKitView.url?.fragment == "/start", "the page lost its route: \(view.webKitView.url?.absoluteString ?? "-")")
        let scrollY = await view.callPageFunction("return window.scrollY;") as? NSNumber
        #expect(scrollY?.intValue == 1234, "the page lost its scroll: \(String(describing: scrollY))")
    }

    @Test func aPageChromiumCanServeLiveStaysInChromium() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        hosting.servesLivePages = true
        let (view, page, window) = try await shownInChromium(hosting, scrollY: 0)
        defer {
            window.closeAfterTest()
            view.close()
        }

        await WebDevOverrideWatcher.reloadPages(live: true, hosting: hosting, pages: [view], served: WebBundleServedViews(), watcher: WebDevOverrideWatcher())?.value

        #expect(view.chromiumPage === page)
        #expect(page.reloads == 1, "Chromium serves the loop: the page reloads in place")
    }

    @Test func aPageThePersonKeepsInChromiumWithNoLoopIsLeftAlone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page, window) = try await shownInChromium(hosting, scrollY: 0)
        defer {
            window.closeAfterTest()
            view.close()
        }

        await WebDevOverrideWatcher.reloadPages(live: false, hosting: hosting, pages: [view], served: WebBundleServedViews(), watcher: WebDevOverrideWatcher())?.value

        #expect(view.chromiumPage === page)
        #expect(!page.closed)
    }
}
