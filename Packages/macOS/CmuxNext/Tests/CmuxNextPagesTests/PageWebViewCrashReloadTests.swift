import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// "why does cmux-next's browser keep refreshing and reloading?" (Leo, 2026-10-26). The agent
/// chat's page reloaded itself after its first three renderer exits, and only then showed the
/// crash notice; a reload builds the chat again without what its page held (an open menu, the
/// caret, an IME composition, chips not yet sent). A host that shows the notice
/// (`reloadsAfterCrash` false, the agent chat) gets every crash and no reload.
@MainActor
struct PageWebViewCrashReloadTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.crash-reload", resource: "crash-reload", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    private func started(_ hosting: FakeChromiumHosting) async throws -> (PageWebView, FakeChromiumPage) {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.first)
        return (view, page)
    }

    @Test func aHostThatShowsTheNoticeGetsEveryCrashAndNoReload() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started(FakeChromiumHosting())
        view.reloadsAfterCrash = false
        var reports: [Bool] = []
        view.onCrash = { _, reloading in reports.append(reloading) }
        page.onEvent?(.crashed)
        page.onEvent?(.crashed)
        #expect(page.reloads == 0, "a crashed agent chat reloaded by itself")
        #expect(reports == [false, false], "the host was not told to show its notice")

        // The Chromium start deadline is off: its WebKit fallback would load the page by itself.
        #expect(view.chromiumSession?.deadline.isScheduled == false, "the start deadline can still reload the crashed page")
        #expect(view.showsChromium)

        // The notice's Reload is the person's.
        view.reloadAfterCrashes()
        #expect(page.reloads == 1)
        view.close()
    }

    /// The Chromium browser ending (`.ended`) under such a host shows the notice too: the page
    /// reopens in WebKit only on Reload.
    @Test func theBrowserEndingShowsTheNoticeAndWaitsForReload() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started(FakeChromiumHosting())
        view.reloadsAfterCrash = false
        var reports: [Bool] = []
        view.onCrash = { _, reloading in reports.append(reloading) }
        page.onEvent?(.ended)
        #expect(reports == [false])
        #expect(!view.showsChromium)
        #expect(view.webKitLoadsOnReload, "the page reopened in WebKit by itself")
        #expect(view.webView.url == nil)
        view.reloadAfterCrashes()
        #expect(!view.webKitLoadsOnReload)
        #expect(view.webView.url != nil, "Reload started no WebKit load, so no new web content process")
        view.close()
    }

    /// Leo's Mac, 2026-11-01: WebKit's GPU process failed three times, WebKit ended every web
    /// content process, and 19 agent chats that showed in Chromium got the crash notice and a
    /// reset bridge, though their Chromium renderer still ran. The hidden WebKit view's end ends
    /// nothing of a page that shows in Chromium.
    @Test func aHiddenWebKitEndUnderAChromiumPageEndsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started(FakeChromiumHosting())
        view.reloadsAfterCrash = false
        var reports: [Bool] = []
        view.onCrash = { _, reloading in reports.append(reloading) }
        view.webContentEnded(PageTermination(reason: .unknown))
        view.webViewWebContentProcessDidTerminate(view.webView)
        #expect(reports.isEmpty, "the host was told a live Chromium page crashed")
        #expect(view.showsChromium && view.lastTermination == nil)
        #expect(page.reloads == 0)

        // Its Chromium renderer ending is still the page's end.
        page.onEvent?(.crashed)
        #expect(reports == [false])
        view.close()
    }

    /// Other app pages keep their bounded automatic reload.
    @Test func otherPagesStillReloadUpToTheLimit() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started(FakeChromiumHosting())
        var reports: [Bool] = []
        view.onCrash = { _, reloading in reports.append(reloading) }
        for _ in 0...PageCrashReloads.limit { page.onEvent?(.crashed) }
        #expect(page.reloads == PageCrashReloads.limit)
        #expect(reports == Array(repeating: true, count: PageCrashReloads.limit) + [false])
        view.close()
    }
}
