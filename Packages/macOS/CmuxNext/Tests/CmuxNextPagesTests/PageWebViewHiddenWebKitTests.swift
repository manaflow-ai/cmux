import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// Leo's Mac, 2026-11-01: WebKit's GPU process stopped answering three times in 20 s, WebKit
/// killed it each time and then ended every web content process, and 19 agent chats that showed
/// in Chromium got the crash notice. Each of them had a WebKit process only because a script ran
/// in its hidden WebKit view before Chromium attached (WebKit launches a process to run script in
/// a view that never loaded). A page that shows in Chromium starts no WebKit process.
@MainActor
struct PageWebViewHiddenWebKitTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.hidden-webkit", resource: "hidden-webkit", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-hidden-webkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    @Test func aChromiumPageStartsNoWebKitProcess() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        #expect(view.showsChromium)
        // What a pane does to a live page: zoom, theme pushes, scripts.
        view.additionalZoom = 1.25
        view.applyUIScale()
        view.evaluate("document.title")
        #expect(view.webKitView.url == nil, "the hidden WebKit view loaded a document")
        // WebKit reports a process it launched for a script only once the launch finished, so
        // the check waits for one (the full wait when, as it should, none comes).
        let launched = await Self.webContentPid(of: view.webKitView, within: .seconds(3))
        #expect(launched == 0, "the hidden WebKit view of a Chromium page runs web content process \(launched)")
        view.close()
    }

    /// The view's web content pid as soon as WebKit reports one, or 0 after `wait`.
    private static func webContentPid(of webView: WKWebView, within wait: Duration) async -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now + wait
        while clock.now < deadline {
            let pid = PageTermination.webContentPid(of: webView)
            if pid != 0 { return pid }
            try? await clock.sleep(for: .milliseconds(50))
        }
        return PageTermination.webContentPid(of: webView)
    }
}
