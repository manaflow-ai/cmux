@testable import CmuxNextBrowser
import Darwin
import CmuxNextTestSupport
import Testing
import WebKit

/// A hidden WebKit page freezes like a Chromium one (`WebKitTab+Freeze`): the hibernation planner's
/// `freezer` finds a WebKit tab, and its freeze and thaw reach the page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebKitTabFreezeTests {
    @Test func aWebKitTabFreezesAndThaws() async throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        let freezing = try #require((tab as any BrowserTab) as? any BrowserFreezing)
        #expect(tab.webView.responds(to: WebKitTab.suspendSelector))
        // WebKit launches a page's process at its first load and suspends only a page whose process runs.
        #expect(!freezing.setFrozen(true), "a page with no web process froze")
        try await Self.loadTallPage(in: tab)
        #expect(freezing.setFrozen(true))
        #expect(freezing.setFrozen(false))
    }

    /// https://github.com/manaflow-ai/cmux/issues/44019: NIGHTLY 1.0.0-nightly.4376544293601 crashed
    /// (`NSInternalInconsistencyException`, "The WKWebView is suspended") when the history writer saved a
    /// frozen tab and measured its scroll: a suspended WKWebView raises from every script, snapshot, find and
    /// navigation call, and Swift cannot catch that. A frozen tab answers each of them without raising, its
    /// saved session keeps the scroll it last knew, and a navigation thaws it first.
    @Test func aFrozenWebKitTabAnswersEveryCallWithoutRaising() async throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        try await Self.loadTallPage(in: tab)
        _ = try await tab.evaluate("window.scrollTo(0, 300); window.scrollY", world: .page, gesture: .cmux)
        let live = try #require(await tab.savedSession(measuringScroll: true))
        #expect(live.entries[live.current].scrollY == 300)

        #expect(tab.setFrozen(true))
        #expect(tab.isFrozen)
        #expect(!tab.setFrozen(true), "a frozen page froze twice")
        // The history writer's save (`BrowserHistoryWriter.flushNow`), the call that crashed.
        #expect(await tab.currentScrollY() == nil)
        let frozen = try #require(await tab.savedSession(measuringScroll: true))
        #expect(frozen.entries.map(\.url) == live.entries.map(\.url))
        #expect(frozen.entries[frozen.current].scrollY == 300, "the frozen tab's session lost its last known scroll")
        await #expect(throws: BrowserTabError.frozen) { try await tab.evaluate("1", world: .isolated, gesture: .cmux) }
        await #expect(throws: BrowserTabError.frozen) { try await tab.evaluate("1", world: .page, gesture: .agent) }
        await #expect(throws: BrowserTabError.frozen) { try await tab.callFunction("return 1", gesture: .cmux) }
        await #expect(throws: BrowserTabError.frozen) { try await tab.callFunction("return 1", gesture: .agent) }
        await #expect(throws: BrowserTabError.frozen) { try await tab.snapshot() }
        #expect(await tab.find("tall", direction: .forward, caseSensitive: false) == .none)
        tab.clearFind()
        tab.exitContentFullscreen()

        // A command WebKit refuses on a suspended page resumes it first.
        tab.stop()
        #expect(!tab.isFrozen)
        #expect(try await tab.evaluate("6 * 7", world: .page, gesture: .cmux) == .number(42))
        #expect(tab.setFrozen(true))
        tab.reload()
        #expect(!tab.isFrozen)
        #expect(try await tab.evaluate("6 * 7", world: .page, gesture: .agent) == .number(42))
        // Another tab of the site zoomed (`SiteZoomFollower`).
        #expect(tab.setFrozen(true))
        tab.setZoom(1.25)
        #expect(!tab.isFrozen)
        #expect(tab.webView.pageZoom == 1.25)
        // A hidden tab closed while frozen (the `defer`) stops its load on a live page.
        #expect(tab.setFrozen(true))
    }

    /// A frozen page whose web process ended (jetsam takes a suspended page's process first) stays suspended
    /// in WebKit for good: `_resumePage:` needs a running process, and every later call raised, a reload and
    /// a close included. Each call now skips WebKit, and the host hears of the loss to replace the page.
    @Test func aFrozenTabWhosePageProcessEndedNeverRaises() async throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        try await Self.loadTallPage(in: tab)
        guard case .pids(let pids) = tab.contentProcesses, let pid = pids.first else {
            Issue.record("the loaded page has no web process")
            return tab.close()
        }
        let lost = Counter()
        tab.onFrozenPageLost = { lost.count += 1 }
        #expect(tab.setFrozen(true))
        #expect(kill(pid, SIGKILL) == 0)
        for _ in 0..<600 where tab.state.processExit == nil { try await Task.sleep(for: .milliseconds(25)) }
        try #require(tab.state.processExit != nil, "the killed page never reported its end")
        #expect(lost.count == 1)
        #expect(tab.isFrozen, "WebKit keeps a page suspended once its process ended")
        #expect(!tab.setFrozen(false))

        #expect(await tab.savedSession(measuringScroll: true) != nil)
        await #expect(throws: BrowserTabError.frozen) { try await tab.evaluate("1", world: .page, gesture: .agent) }
        await #expect(throws: BrowserTabError.frozen) { try await tab.snapshot() }
        #expect(tab.hibernationState() != nil, "the lost page's history is gone")
        tab.reload()
        tab.load(try #require(URL(string: "https://freeze.example/next")))
        tab.goBack()
        tab.stop()
        tab.setZoom(1.5)
        tab.close()
    }

    @Test func aClosedWebKitTabIgnoresAFreeze() {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        tab.close()
        #expect(!tab.setFrozen(true))
    }

    @MainActor final class Counter { var count = 0 }

    /// A page taller than the view at a web URL, so the saved session keeps it and it can scroll.
    private static func loadTallPage(in tab: WebKitTab) async throws {
        tab.webView.loadHTMLString("<!doctype html><title>tall</title><div style=\"height:5000px\">tall</div>",
                                   baseURL: URL(string: "https://freeze.example/"))
        for _ in 0..<600 {
            if tab.state.url != nil,
               (try? await tab.evaluate("document.readyState === 'complete' && document.title === 'tall'", world: .page, gesture: .cmux)) == .bool(true) {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw BrowserTabError.timedOut("load")
    }
}
