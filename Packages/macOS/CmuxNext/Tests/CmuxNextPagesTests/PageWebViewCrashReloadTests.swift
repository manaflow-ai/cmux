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

    /// Leo's Mac, 2026-11-21: each quit logged every Chromium page (an agent chat, two New Tab pages) as
    /// "web content ended ... engine=webkit:chromium-failed; loads again by itself", and started a WebKit load
    /// of each while the app quit. The engine's stop for quit (`.engineStopped`) reopens nothing in WebKit and
    /// reports no crash, on a host with the notice and on one that reloads.
    @Test func theEnginesStopForQuitIsNoCrashAndNoWebKitFallback() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for reloadsAfterCrash in [false, true] {
            let (view, page) = try await started(FakeChromiumHosting())
            view.reloadsAfterCrash = reloadsAfterCrash
            var reports: [Bool] = []
            view.onCrash = { _, reloading in reports.append(reloading) }
            page.onEvent?(.engineStopped)
            #expect(reports.isEmpty, "the quit was reported as a crash (reloadsAfterCrash \(reloadsAfterCrash))")
            #expect(view.showsChromium, "the page fell back to WebKit on quit")
            #expect(view.lastTermination == nil)
            #expect(!view.webKitLoadsOnReload)
            #expect(view.webView.url == nil, "a WebKit load started while the app quit")
            #expect(page.reloads == 0)
            view.close()
        }
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

    /// hq#27887, class 2 (Leo, 2026-11-22: "we need to make sure any solutions that reloading would help
    /// with, we never encounter those classes of bugs in the first place"): a page that crashes as it
    /// loads, under app health's ladder. Each health repair of the crashed page reloaded it under the
    /// crash notice and reset its crash count, so it loaded again every few minutes forever. Now a
    /// crashed page its host holds (the notice, the agent chat's own retry, the count run out) is left to
    /// the host: 30 health repairs load it 0 times (before: 30), and the person's Reload still does.
    @Test func healthRepairsLeaveACrashedPageItsHostHoldsAlone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        for reloadsAfterCrash in [false, true] {
            let (view, page) = try await started(FakeChromiumHosting())
            view.reloadsAfterCrash = reloadsAfterCrash
            let crashes = reloadsAfterCrash ? PageCrashReloads.limit + 1 : 1
            for _ in 0..<crashes { page.onEvent?(.crashed) }
            #expect(view.holdsCrash, "the host gave up on the crash but the page is not held (reloadsAfterCrash \(reloadsAfterCrash))")
            let held = page.reloads
            var ran = 0
            for attempt in 0..<30 {
                if attempt.isMultiple(of: 2) {
                    if await view.reloadKeepingState() { ran += 1 }
                } else if view.restartRenderer() {
                    ran += 1
                }
            }
            #expect(ran == 0, "app health repaired a crashed page its host holds (reloadsAfterCrash \(reloadsAfterCrash))")
            #expect(page.reloads == held, "app health reloaded a held crashed page \(page.reloads - held) times")

            // The person's Reload brings it back and the page is no longer held.
            view.reloadAfterCrashes()
            #expect(page.reloads == held + 1)
            #expect(!view.holdsCrash)
            view.close()
        }
    }

    /// A page that crashed while its host reloads it by itself (inside ``PageCrashReloads``) is not held:
    /// the host's reload is underway.
    @Test func aCrashTheHostReloadsIsNotHeld() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (view, page) = try await started(FakeChromiumHosting())
        page.onEvent?(.crashed)
        #expect(page.reloads == 1)
        #expect(!view.holdsCrash)
        view.close()
    }
}
