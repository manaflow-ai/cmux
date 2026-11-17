import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// Cmd-N in NIGHTLY 1.0.0-nightly.3968001295301 sometimes left the new workspace's New Tab field
/// without the keyboard: the page (a prewarmed spare whose browser already existed) asked for focus
/// a moment before its Chromium window showed, `setFocused(true)` refused a hidden page, and only a
/// browser's creation (`attach`) replayed that ask. The page then showed with no focus, and the
/// focus applier, which had already asked, never asked again.
@MainActor @Suite(.serialized, .closesItsWindows) struct CEFDeferredFocusTests {
    /// A page with its browser asks for focus before its view is in a window; it gets it once it shows.
    @Test func focusAskedBeforeThePageShowsIsGrantedWhenItShows() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 7)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty, "a page that does not show takes no focus")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        #expect(FocusSpyShim.granted.isEmpty, "a page shown in this turn took focus in this turn")
        Self.endTurn()
        #expect(FocusSpyShim.granted == [7])
    }

    /// A shown page the content lifecycle hid (its first paint not there yet) asks for focus; it gets
    /// it when the lifecycle shows it again.
    @Test func focusAskedWhileTheLifecycleHidThePageIsGrantedWhenItShowsAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        Self.endTurn()
        tab.setContentVisible(false)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty)

        tab.setContentVisible(true)
        #expect(FocusSpyShim.granted == [8])
    }

    /// An ask taken back (focus moved on) before the page showed is not granted later.
    @Test func focusTakenBackBeforeThePageShowsIsNotGranted() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 9)

        tab.setFocused(true)
        tab.setFocused(false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        Self.endTurn()
        #expect(FocusSpyShim.granted.isEmpty)
    }

    /// NIGHTLY 1.0.0-nightly.4093446036501 beachballed for good: a workspace switch hid an ancestor of
    /// the focused page's view. Chromium ordered the page window out inside AppKit's hide walk, before
    /// the page's own `viewDidHide`; the cmux window took the keys, the focus applier asked again, and
    /// the grant showed the page window again, around and around in one main-thread turn. A page
    /// under a hidden ancestor takes no focus; it gets it when its view shows again.
    @Test func focusAskedWhileAnAncestorHidesIsGrantedWhenItShowsAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 10)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // Hidden first in AppKit's walk, as Chromium's view was: it asks for focus mid-hide.
        let chromium = HideSpyView(frame: workspace.bounds)
        workspace.addSubview(chromium)
        workspace.addSubview(tab.contentView)
        try #require(window.contentView).addSubview(workspace)
        Self.endTurn()
        FocusSpyShim.granted = []
        chromium.onHide = { tab.setFocused(true) }

        workspace.isHidden = true
        #expect(FocusSpyShim.granted.isEmpty, "a page under a hidden ancestor was given focus: \(FocusSpyShim.granted)")

        chromium.onHide = nil
        workspace.isHidden = false
        #expect(FocusSpyShim.granted.isEmpty, "a page shown again in this turn took focus in this turn")
        Self.endTurn()
        #expect(FocusSpyShim.granted == [10])
    }

    /// The same ask from inside the page's own view (where Chromium's view sits), whichever order
    /// AppKit tells a view and its subviews that an ancestor hid.
    @Test func focusAskedFromInsideThePageWhileAnAncestorHidesIsGrantedWhenItShowsAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 11)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        try #require(window.contentView).addSubview(workspace)
        workspace.addSubview(tab.contentView)
        let chromium = HideSpyView(frame: tab.contentView.bounds)
        tab.contentView.addSubview(chromium)
        Self.endTurn()
        FocusSpyShim.granted = []
        chromium.onHide = { tab.setFocused(true) }

        workspace.isHidden = true
        #expect(FocusSpyShim.granted.isEmpty, "a page under a hidden ancestor was given focus: \(FocusSpyShim.granted)")

        chromium.onHide = nil
        workspace.isHidden = false
        Self.endTurn()
        #expect(FocusSpyShim.granted == [11])
    }

    /// reopen-browser-plain-keys cycle B (REOPEN VIDEO 7660, 7710): keys sent on when the browser existed reached the
    /// empty document the restore replaced; keys sent on at the restored document's commit reached a page whose
    /// script had not run (its focused field and key listener did not exist yet). The page is ready for keys once a
    /// real (not blank) document finished loading. Events in CEF's order: loading starts, the commit, the load end,
    /// loading stops.
    @Test func aTabIsReadyForKeysOnceARealDocumentLoaded() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 16)
        #expect(!tab.pageReady, "keys sent on when the browser exists reach the empty document the restore replaces")
        Self.load(runtime, 16, "about:blank")
        #expect(!tab.pageReady, "a blank document's load is not the restored page")
        runtime.handle(.loadingState(browser: 16, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 16, url: "https://example.com/", fromPost: false))
        #expect(!tab.pageReady, "keys sent on at the commit reach a page whose script has not run")
        Self.paint(runtime, 16)
        runtime.handle(.loadEnd(browser: 16, httpStatus: 200))
        runtime.handle(.loadingState(browser: 16, loading: false, canGoBack: false, canGoForward: false))
        #expect(tab.pageReady)
        #expect(reported() == 1, "the tab did not say its real document loaded")
        Self.load(runtime, 16, "https://example.com/next")
        #expect(reported() == 1, "a later navigation ended a hold again")
    }

    /// reopen-browser-plain-keys cycle B, v8 (REOPEN VIDEO 7801: 1 of 3; in every round, pass or fail, the held keys went
    /// on about 46 ms after the page attached, so the page's readiness did not gate them): a navigation that the next
    /// one replaces ends in an aborted load (ERR_ABORTED, -3), and a load end comes while the next navigation is on its
    /// way. Neither is the page the keys must reach: it is ready once Chromium stopped loading (CEF reports that after
    /// every load end and error of the load) with a real document loaded, or with an error page.
    @Test func aTabIsReadyForKeysOnlyOnceLoadingStoppedOnARealDocument() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 17)
        runtime.handle(.loadingState(browser: 17, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadError(browser: 17, code: -3, text: "net::ERR_ABORTED", url: "https://example.com/", chromiumInterstitial: false))
        #expect(!tab.pageReady, "an aborted load (a navigation the next one replaced) is no page")
        runtime.handle(.loadStart(browser: 17, url: "https://example.com/", fromPost: false))
        runtime.handle(.loadEnd(browser: 17, httpStatus: 200))
        #expect(!tab.pageReady, "a load end while Chromium still loads: the next navigation replaces this document")
        runtime.handle(.loadStart(browser: 17, url: "https://example.com/?c=1", fromPost: false))
        Self.paint(runtime, 17)
        runtime.handle(.loadEnd(browser: 17, httpStatus: 200))
        #expect(tab.pageReady, "the main frame's document painted and loaded, and the page is not ready (its subframes may load for seconds)")
        runtime.handle(.loadingState(browser: 17, loading: false, canGoBack: false, canGoForward: false))
        #expect(tab.pageReady)
        #expect(reported() == 1)
        let (failing, failed) = try Self.readyTab(runtime, browser: 18)
        runtime.handle(.loadingState(browser: 18, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadError(browser: 18, code: -105, text: "net::ERR_NAME_NOT_RESOLVED", url: "https://nowhere.invalid/", chromiumInterstitial: false))
        runtime.handle(.loadingState(browser: 18, loading: false, canGoBack: false, canGoForward: false))
        #expect(failing.pageReady && failed() == 1, "an error page takes keys: the hold must not wait for its bound")
    }

    /// Lead on STATUS 7828: the second ready-for-keys in the journal (about 430 ms after the first) was another page's
    /// (an app page with no key hold). One browser reports once, whatever loads after; a browser attached again (a
    /// renderer restart) is a new page and reports once when it is ready again, never before.
    @Test func aTabReportsReadyOncePerBrowserAndAgainOnlyAfterItIsReadyAgain() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 19)
        Self.load(runtime, 19, "https://example.com/")
        Self.load(runtime, 19, "https://example.com/again")
        runtime.handle(.loadingState(browser: 19, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadError(browser: 19, code: -105, text: "net::ERR_NAME_NOT_RESOLVED", url: "https://nowhere.invalid/", chromiumInterstitial: false))
        runtime.handle(.loadingState(browser: 19, loading: false, canGoBack: false, canGoForward: false))
        #expect(reported() == 1, "one browser reported ready \(reported()) times")
        tab.attach(browser: 19)
        #expect(!tab.pageReady && reported() == 1, "a browser attached again was ready before its page loaded")
        Self.load(runtime, 19, "https://example.com/")
        #expect(tab.pageReady && reported() == 2)
    }

    /// Review of #32633: a Chromium New Tab page (a blank document) never counted as ready, so Cmd-L after Escape waited
    /// the whole bound. A page with nothing to load takes keys once Chromium created it; a page asked to show a blank
    /// document is ready once that blank document loaded.
    @Test func aPageWithNothingToLoadIsReadyAtOnceAndABlankTargetCountsItsBlankDocument() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fresh, freshReported) = try Self.readyTab(runtime, browser: 20, restored: nil)
        #expect(fresh.pageReady && freshReported() == 1, "a page with nothing to load was not ready once Chromium created it")
        Self.load(runtime, 20, "about:blank")
        #expect(freshReported() == 1)
        let (blank, blankReported) = try Self.readyTab(runtime, browser: 21, restored: "about:blank")
        #expect(!blank.pageReady)
        Self.load(runtime, 21, "about:blank")
        #expect(blank.pageReady && blankReported() == 1, "a tab asked to show a blank page never got ready: its keys waited the whole bound")
    }

    /// Lead on STATUS 7916 (v6 of #32633, cycle B 0 of 3): a reopened tab that loads its page by address (no saved
    /// navigation state) counted as ready at its attach, so the held keys went to the empty document before its restore
    /// navigation began. In the journal order: the browser exists, an empty document loads, then the page's navigation
    /// starts and its document loads. The keys wait for that document.
    @Test func aReopenedTabLoadingByAddressWaitsForItsPageNotTheEmptyDocumentBeforeIt() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 22, restored: "http://127.0.0.1:8080/?c=1")
        #expect(!tab.pageReady && reported() == 0, "a reopened tab was ready at its attach, before its page's navigation began")
        Self.load(runtime, 22, "about:blank")
        #expect(!tab.pageReady, "the empty document before the restore navigation counted as the page")
        runtime.handle(.loadingState(browser: 22, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 22, url: "http://127.0.0.1:8080/?c=1", fromPost: false))
        #expect(!tab.pageReady, "ready at the commit, before the page's script ran")
        Self.paint(runtime, 22)
        runtime.handle(.loadEnd(browser: 22, httpStatus: 200))
        runtime.handle(.loadingState(browser: 22, loading: false, canGoBack: false, canGoForward: false))
        #expect(tab.pageReady && reported() == 1)
    }

    /// Lead on STATUS 8132 (cycleb-v11 set 1 a3: the restored tab never logged ready-for-keys and its held keys waited
    /// the whole 2 s bound, though the page took them then). Two orders of Chromium's events lost the signal: the first
    /// paint message comes on the page channel and can reach the app before the commit (`.loadStart`) of its own
    /// document, which then forgot it; and loading can stop before the load end, after which no event asked again.
    @Test func theReadySignalSurvivesAPaintBeforeItsCommitAndAStopBeforeTheLoadEnd() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (early, earlyReported) = try Self.readyTab(runtime, browser: 25, restored: "http://127.0.0.1:8080/?c=1")
        runtime.handle(.loadingState(browser: 25, loading: true, canGoBack: false, canGoForward: false))
        Self.paint(runtime, 25) // the new document's first paint, delivered before its commit
        runtime.handle(.loadStart(browser: 25, url: "http://127.0.0.1:8080/?c=1", fromPost: false))
        runtime.handle(.loadEnd(browser: 25, httpStatus: 200))
        runtime.handle(.loadingState(browser: 25, loading: false, canGoBack: false, canGoForward: false))
        #expect(early.pageReady && earlyReported() == 1, "a paint delivered before its document's commit was forgotten: the keys waited the whole bound")
        let (late, lateReported) = try Self.readyTab(runtime, browser: 26, restored: "http://127.0.0.1:8080/?c=2")
        runtime.handle(.loadingState(browser: 26, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 26, url: "http://127.0.0.1:8080/?c=2", fromPost: false))
        Self.paint(runtime, 26)
        runtime.handle(.loadingState(browser: 26, loading: false, canGoBack: false, canGoForward: false))
        #expect(!late.pageReady, "ready before the document's load end")
        runtime.handle(.loadEnd(browser: 26, httpStatus: 200))
        #expect(late.pageReady && lateReported() == 1, "loading stopped before the load end, and nothing asked again: the keys waited the whole bound")
        let (twice, twiceReported) = try Self.readyTab(runtime, browser: 27, restored: "http://127.0.0.1:8080/?c=3")
        runtime.handle(.loadingState(browser: 27, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 27, url: "http://127.0.0.1:8080/?c=3", fromPost: false))
        Self.paint(runtime, 27) // a first document of this load painted
        runtime.handle(.loadStart(browser: 27, url: "http://127.0.0.1:8080/?c=4", fromPost: false)) // replaced in the same load
        runtime.handle(.loadEnd(browser: 27, httpStatus: 200))
        runtime.handle(.loadingState(browser: 27, loading: false, canGoBack: false, canGoForward: false))
        #expect(!twice.pageReady && twiceReported() == 0, "the paint of a document the same load replaced counted for the next one")
    }

    /// Review of #32633 (6594624994): the hold waited until every frame stopped loading (ads, slow iframes), so on a
    /// heavy page its keys waited up to the 2 s bound after the page showed and took clicks. Chrome's own signals are the
    /// main frame's: its document loaded and painted content. An error page is ready at its error.
    @Test func aPageIsReadyAtItsMainFrameLoadEndAndPaintWhileSubframesStillLoad() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 28, restored: "https://example.com/heavy")
        runtime.handle(.loadingState(browser: 28, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 28, url: "https://example.com/heavy", fromPost: false))
        Self.paint(runtime, 28)
        runtime.handle(.loadEnd(browser: 28, httpStatus: 200))
        #expect(tab.pageReady && reported() == 1, "the keys waited for the page's subframes")
        let (failed, failedReported) = try Self.readyTab(runtime, browser: 29, restored: "https://nowhere.invalid/")
        runtime.handle(.loadingState(browser: 29, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadError(browser: 29, code: -105, text: "net::ERR_NAME_NOT_RESOLVED", url: "https://nowhere.invalid/", chromiumInterstitial: false))
        #expect(failed.pageReady && failedReported() == 1, "an error page waited for loading to stop")
    }

    /// A shown tab whose browser Chromium created, and a count of its ready-for-keys reports. `restored`: the URL the tab
    /// was asked to show before Chromium made it (a reopen by address; nil: a page with nothing to load).
    private static func readyTab(_ runtime: CEFRuntime, browser: Int32, restored: String? = "https://example.com/") throws -> (CEFTab, () -> Int) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        host.add(tab)
        if let restored, let url = URL(string: restored) { tab.load(url) } // as the app asks for it before Chromium made the page
        final class Count { var value = 0 }
        let count = Count()
        tab.onReadyForKeys = { count.value += 1 }
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
        runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
        return (tab, { count.value })
    }

    /// #33940 (follow-up of #32633; REOPEN VIDEO round rpk-trace2-cmux22/a3, STATUS 8918): the restored document
    /// loaded and Chromium stopped loading, but its first paint report never came (it went before the lifecycle
    /// observer started, or was lost). The page then never counted as ready and the keys waited the whole 2 s bound.
    /// The tab asks the page once (a buffered paint observer, which never misses a paint that came before it asked):
    /// a page that painted is ready, with no report and no bound.
    @Test func aLoadedPageWhosePaintReportIsLostIsReadyFromThePagesOwnAnswer() async throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 31, restored: "http://127.0.0.1:8080/?c=1")
        let asked = Asked()
        tab.paintQuery = { _ in asked.count += 1; return true }
        runtime.handle(.loadingState(browser: 31, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 31, url: "http://127.0.0.1:8080/?c=1", fromPost: false))
        runtime.handle(.loadEnd(browser: 31, httpStatus: 200))
        runtime.handle(.loadingState(browser: 31, loading: false, canGoBack: false, canGoForward: false))
        for _ in 0..<50 where !tab.pageReady { await Task.yield() } // no paint report comes
        #expect(tab.pageReady && reported() == 1, "a loaded page whose paint report was lost waited for a report that never comes")
        #expect(asked.count == 1, "the page was asked \(asked.count) times")
    }

    /// Lead on STATUS 9778 (a page that never paints content, REOPEN rounds rpk-empty-*: 6/6 waited the 2 s bound):
    /// a document whose first frame is presented takes input, whether or not it has content. Chromium says so with its
    /// `firstPaint` lifecycle event; `firstContentfulPaint` comes only once the page shows text (an empty field: when
    /// the person types). The page is ready at its first frame, never at the bound.
    @Test func aLoadedPageIsReadyAtItsFirstFrameEvenWithNoContent() async throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 33, restored: "http://127.0.0.1:8080/?c=1")
        tab.paintQuery = { _ in nil } // the page's own answer does not come (its promise waits for content)
        runtime.handle(.loadingState(browser: 33, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 33, url: "http://127.0.0.1:8080/?c=1", fromPost: false))
        runtime.handle(.loadEnd(browser: 33, httpStatus: 200))
        runtime.handle(.loadingState(browser: 33, loading: false, canGoBack: false, canGoForward: false))
        #expect(!tab.pageReady, "ready before the document's first frame")
        runtime.handle(.devToolsMessage(browser: 33, json: Self.lifecycle("firstPaint")))
        #expect(tab.pageReady && reported() == 1, "a loaded page whose first frame is presented, with no content, waited for content")
    }

    /// A Chromium lifecycle event of the main frame (`CEFFirstPaintBridge`: every frame counts before the main frame is known).
    private static func lifecycle(_ name: String) -> String {
        #"{"method":"Page.lifecycleEvent","params":{"frameId":"MAIN","loaderId":"L1","name":"\#(name)","timestamp":1.5}}"#
    }

    /// The page's answer is for the document it was asked about: an answer that comes after the next document
    /// committed makes nothing ready, and a failed answer keeps the page waiting for its paint report.
    @Test func aPaintAnswerForAReplacedDocumentOrAFailedAnswerMakesNothingReady() async throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 32, restored: "http://127.0.0.1:8080/?c=1")
        let answer = Asked()
        tab.paintQuery = { _ in
            answer.count += 1
            while !answer.release { await Task.yield() }
            return answer.value
        }
        runtime.handle(.loadingState(browser: 32, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 32, url: "http://127.0.0.1:8080/?c=1", fromPost: false))
        runtime.handle(.loadEnd(browser: 32, httpStatus: 200))
        runtime.handle(.loadingState(browser: 32, loading: false, canGoBack: false, canGoForward: false))
        for _ in 0..<50 where answer.count == 0 { await Task.yield() }
        #expect(answer.count == 1, "the loaded page was not asked whether it painted")
        runtime.handle(.loadingState(browser: 32, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 32, url: "http://127.0.0.1:8080/?c=2", fromPost: false)) // the next document
        (answer.value, answer.release) = (true, true)
        for _ in 0..<50 { await Task.yield() }
        #expect(!tab.pageReady && reported() == 0, "the first document's answer made the next one ready")
        answer.value = nil
        runtime.handle(.loadEnd(browser: 32, httpStatus: 200))
        runtime.handle(.loadingState(browser: 32, loading: false, canGoBack: false, canGoForward: false))
        for _ in 0..<50 { await Task.yield() }
        #expect(!tab.pageReady, "a failed answer made the page ready")
        Self.paint(runtime, 32)
        #expect(tab.pageReady && reported() == 1, "the paint report after a failed answer did not make the page ready")
    }

    @MainActor private final class Asked {
        var count = 0
        var release = false
        var value: Bool?
    }

    /// One whole load of `url` in CEF's order, with its document's first contentful paint before its load end.
    private static func load(_ runtime: CEFRuntime, _ browser: Int32, _ url: String) {
        runtime.handle(.loadingState(browser: browser, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: browser, url: url, fromPost: false))
        paint(runtime, browser)
        runtime.handle(.loadEnd(browser: browser, httpStatus: 200))
        runtime.handle(.loadingState(browser: browser, loading: false, canGoBack: false, canGoForward: false))
    }

    /// The main frame's document first painted content (fork API 29's first paint channel, `BrowserFirstPaintScript`).
    private static func paint(_ runtime: CEFRuntime, _ browser: Int32) {
        runtime.handle(.pageMessage(browser: browser, mainFrame: true, channel: BrowserFirstPaintScript.channel, payload: "{}"))
    }

    /// Lead on STATUS 8055 (cycle B round a3 of cycleb-v9: the page had focus but got none of the 11 keys sent 4 ms
    /// after ready-for-keys, 62 ms after its navigation began): Chromium drops input to a new document before its
    /// first paint, so "stopped loading on a document" is not yet "the document takes keys". The page is ready once
    /// it stopped loading AND its document painted content, in either order; a paint of the document before the
    /// navigation does not count.
    @Test func aReopenedPageIsReadyForKeysOnlyOnceItsDocumentPainted() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, reported) = try Self.readyTab(runtime, browser: 23, restored: "http://127.0.0.1:8080/?c=1")
        Self.paint(runtime, 23) // the empty document before the restore navigation painted
        runtime.handle(.loadingState(browser: 23, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 23, url: "http://127.0.0.1:8080/?c=1", fromPost: false))
        runtime.handle(.loadEnd(browser: 23, httpStatus: 200))
        runtime.handle(.loadingState(browser: 23, loading: false, canGoBack: false, canGoForward: false))
        #expect(!tab.pageReady && reported() == 0, "ready before the restored document painted: Chromium drops the keys sent now")
        Self.paint(runtime, 23)
        #expect(tab.pageReady && reported() == 1, "the restored document painted after it stopped loading, and the page is not ready")
        let (early, earlyReported) = try Self.readyTab(runtime, browser: 24, restored: "http://127.0.0.1:8080/?c=2")
        runtime.handle(.loadingState(browser: 24, loading: true, canGoBack: false, canGoForward: false))
        runtime.handle(.loadStart(browser: 24, url: "http://127.0.0.1:8080/?c=2", fromPost: false))
        Self.paint(runtime, 24)
        #expect(!early.pageReady, "ready at the first paint, before loading stopped")
        runtime.handle(.loadEnd(browser: 24, httpStatus: 200))
        runtime.handle(.loadingState(browser: 24, loading: false, canGoBack: false, canGoForward: false))
        #expect(early.pageReady && earlyReported() == 1, "painted, then stopped loading, and the page is not ready")
    }

    /// browser-click-then-type (STATUS 7374): the grant gave the page focus but its page window did not become key
    /// (a fresh launch, a page loaded from the address bar). The cmux window kept the keys with itself as first
    /// responder, and every plain key typed for the page reached no view. The page window takes the keys from the cmux
    /// window that shows it: one key change.
    @Test func aGrantThatMovesNoKeyHandsTheKeysFromTheCmuxWindowToThePageWindow() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 12)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        Self.endTurn() // shown before the ask's turn (a page shown in it takes focus after its commit)
        let page = pageWindow(over: tab, in: window)
        defer { page.closeAfterTest() }
        let keys = KeyRecorder(key: window)
        tab.keyWindows = keys.seam

        tab.setFocused(true)
        #expect(FocusSpyShim.granted == [12])
        #expect(keys.key === page, "the page has focus but the cmux window kept the keys")
        #expect(keys.made.count == 1, "one focus request made \(keys.made.count) key changes")
    }

    /// The same hand-over for a grant that waited for the page to show (``CEFTab/grantPendingFocusIfShown()``): a
    /// hidden page takes neither focus nor the keys, and gets both when it shows.
    @Test func aDelayedGrantThatMovesNoKeyAlsoHandsTheKeysToThePageWindow() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 13)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        Self.endTurn() // shown before the ask's turn (a page shown in it takes focus after its commit)
        let page = pageWindow(over: tab, in: window)
        defer { page.closeAfterTest() }
        let keys = KeyRecorder(key: window)
        tab.keyWindows = keys.seam
        tab.setContentVisible(false)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty)
        #expect(keys.made.isEmpty, "a hidden page took the keys")

        tab.setContentVisible(true)
        #expect(FocusSpyShim.granted == [13])
        #expect(keys.key === page, "the delayed grant left the keys on the cmux window")
        #expect(keys.made.count == 1)
    }

    /// A grant whose page window became key (CEF moved the keys itself) gets no second key change; an inactive app
    /// (no key window) and another window that has the keys keep them.
    @Test func aGrantTakesNoKeysWhenCEFMovedThemOrAnotherWindowOrNoneHasThem() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 14)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        Self.endTurn() // shown before the ask's turn (a page shown in it takes focus after its commit)
        let page = pageWindow(over: tab, in: window)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: true)
        defer { page.closeAfterTest(); other.closeAfterTest() }
        let keys = KeyRecorder(key: window)
        tab.keyWindows = keys.seam

        FocusSpyShim.onGrant = { MainActor.assumeIsolated { keys.key = page } }
        defer { FocusSpyShim.onGrant = nil }
        tab.setFocused(true)
        #expect(keys.made.isEmpty, "CEF moved the keys and the grant moved them again")

        FocusSpyShim.onGrant = nil
        for key in [nil, other] {
            tab.setFocused(false)
            keys.key = key
            tab.setFocused(true)
            #expect(keys.key === key, "the page took the keys from \(key.map { String(describing: $0) } ?? "an inactive app")")
        }
        #expect(keys.made.isEmpty)
    }

    /// Cmd-N's New Tab page (INSTANT OWNER, PR #36474): its pane host is still empty when the focus applier asks, so the
    /// page keeps the ask and takes no focus (the fork has ordered its window out). The host then gets its area in a
    /// layout pass, and the page takes focus once, after that pass's commit, never inside the layout pass. If this grant
    /// never came, the page would keep focus with no keys and typing would go nowhere.
    @Test func focusAskedWhileTheHostIsEmptyIsGrantedOnceAfterTheCommitThatGivesItAnArea() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 15)
        tab.contentView.frame = .zero
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)

        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty, "a page whose host is empty was given focus")

        tab.contentView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        #expect(FocusSpyShim.granted.isEmpty, "the grant ran inside the layout pass, before its commit")
        let deadline = Date().addingTimeInterval(2)
        while FocusSpyShim.granted.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(FocusSpyShim.granted == [15], "the kept ask was granted \(FocusSpyShim.granted) after the host got its area (want [15] once)")
    }

    /// The page of the workspace Cmd-N built before its key (#36962) is unhidden in the key's turn and the focus applier
    /// asks for focus in that turn. Granted then, the grant and the page window's order-in ran before the first frame
    /// (Time Profiler, cmux22: 10 ms of the swap turn, the key window changed 18-25 ms after the key). A page that becomes
    /// shown in a turn takes no focus in that turn and exactly one grant after its commit; a page shown before the turn
    /// still takes it at once.
    @Test func aPageShownInThisTurnTakesFocusOnlyAfterTheCommit() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, _) = try createdTab(runtime, browser: 17)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        workspace.addSubview(tab.contentView)
        try #require(window.contentView).addSubview(workspace)
        workspace.isHidden = true
        Self.endTurn()
        FocusSpyShim.granted = []

        workspace.isHidden = false
        tab.setFocused(true)
        #expect(FocusSpyShim.granted.isEmpty, "a page shown in this turn took focus before the turn's frame: \(FocusSpyShim.granted)")
        Self.endTurn()
        #expect(FocusSpyShim.granted == [17], "the kept ask was granted \(FocusSpyShim.granted) after the commit (want [17] once)")

        // Shown since before this turn: at once.
        tab.setFocused(false)
        FocusSpyShim.granted = []
        tab.setFocused(true)
        #expect(FocusSpyShim.granted == [17])
    }

    /// Lets the main run loop end this turn: its frame commit, and the work queued after it (`AfterFrameCommit`).
    private static func endTurn() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// A Chromium page window over `tab`'s view, a child of `window`, as the fork places it.
    private func pageWindow(over tab: CEFTab, in window: NSWindow) -> NSWindow {
        let frame = window.convertToScreen(tab.host.hostView.convert(tab.host.hostView.bounds, to: nil))
        let page = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        page.setFrame(frame, display: false)
        window.addChildWindow(page, ordered: .above)
        return page
    }

    /// A tab whose browser Chromium made (`afterCreated`), its view in no window yet.
    /// Detached hosting (fork API 30, STATUS 14261 slice 1): a page detached for a resize motion has no window in its
    /// window server's list, so a focus grant that reaches it then moves no keys and typed keys reach no view after
    /// the landing. Every grant path (a direct ask, a kept ask granted when the page shows or gets an area) attaches
    /// the page first and grants after the attach's commit.
    @Test func aFocusAskForADetachedPageAttachesItBeforeTheGrant() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, host) = try createdTab(runtime, browser: 12)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        Self.endTurn()
        let log = CallLog()
        let fork = CEFLayerHosting.Fork(setLayerHosting: { _, on in on ? 7 : 0 }, setResizeSync: { _, _ in true },
                                        setDetachedHosting: { _, on in log.items.append(on ? "detach" : "attach"); return true })
        let hosting = host.hostView.layerHosting
        hosting.holdsFocus = { false }
        hosting.pageWindowCreated(browser: 12, fork: fork)
        let hosted = Date().addingTimeInterval(2)
        while hosting.page == nil, Date() < hosted { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try #require(hosting.page != nil)
        hosting.resizeMotion(active: true)
        #expect(log.items == ["detach"])
        FocusSpyShim.granted = []
        FocusSpyShim.onGrant = { log.items.append("grant") }
        defer { FocusSpyShim.onGrant = nil }

        // A kept ask granted when the page can take it (the path the review found).
        tab.pendingFocus = true
        tab.grantPendingFocusIfShown()
        #expect(log.items == ["detach", "attach"], "the page attaches before any grant")
        let deadline = Date().addingTimeInterval(2)
        while FocusSpyShim.granted.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(log.items == ["detach", "attach", "grant"])
        hosting.resizeMotion(active: false)
        #expect(log.items == ["detach", "attach", "grant"], "the landing has nothing to attach")
    }

    /// SWITCH STALL 5: Cmd-N's page (built before the key, hidden) is unhidden in the key's turn. The fork orders its
    /// input window in (addChildWindow, then the overlay panel's re-add above it) from a run-loop observer it means for
    /// after the commit, but on macOS 27 that observer fires on the key pass's exit, before the commit: 7.6 ms of
    /// window-server work before the first frame on every press (Time Profiler, cmux22, macOS 27.0, 60 Hz, 2a93dae4).
    /// A hosted page shown in a turn stays detached for that turn (its pixels show from the hosted context, no window is
    /// ordered), attaches after the turn's commit, and a focus ask in the turn is granted only after the attach.
    @Test func aHostedPageShownInThisTurnOrdersItsWindowInOnlyAfterTheCommit() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, host) = try createdTab(runtime, browser: 19)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        workspace.addSubview(tab.contentView)
        try #require(window.contentView).addSubview(workspace)
        Self.endTurn()
        let log = CallLog()
        let fork = CEFLayerHosting.Fork(setLayerHosting: { _, on in on ? 7 : 0 }, setResizeSync: { _, _ in true },
                                        setDetachedHosting: { _, on in log.items.append(on ? "detach" : "attach"); return true })
        let hosting = host.hostView.layerHosting
        hosting.holdsFocus = { false }
        hosting.pageWindowCreated(browser: 19, fork: fork)
        let hosted = Date().addingTimeInterval(2)
        while hosting.page == nil, Date() < hosted { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try #require(hosting.page != nil)
        workspace.isHidden = true
        Self.endTurn()
        FocusSpyShim.granted = []
        FocusSpyShim.onGrant = { log.items.append("grant") }
        defer { FocusSpyShim.onGrant = nil }

        // The key's turn: the workspace shows and the focus applier asks for the page.
        workspace.isHidden = false
        tab.setFocused(true)
        #expect(log.items == ["detach"], "a hosted page shown in this turn must stay out of the window until its frame commits: \(log.items)")
        // The window's display frames: a test window is never on screen, so its display link stays still, and the
        // scheduler's stall tick is a main-actor task that this nested run loop does not run. Tick it by hand.
        let frames = FrameScheduler.forWindow(window)
        let deadline = Date().addingTimeInterval(2)
        while FocusSpyShim.granted.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            frames.frameDidFire()
        }
        #expect(log.items == ["detach", "attach", "grant"], "the page attaches after the commit and takes the focus after the attach: \(log.items)")
        #expect(!hosting.isDetached)
    }

    /// TAB SWITCH TAIL: Ctrl-Tab between two page tabs of one pane. Each page tab has its own Chromium window, so the
    /// switch shows the incoming page's window in the place the leaving page's window still has in that turn. The
    /// pane binds the incoming page's view first (`BrowserPageArea.show`, the host is still hidden then) and the
    /// content lifecycle reveals the tab after (`TabContentCache.reveal`). The page took no first-frame hold: the
    /// show saw a hidden host, and the leaving page's window at the same rect passed for the incoming page's. The fork
    /// then ordered the window in from its run-loop exit observer, 6.7 ms of window-server work per switch that ran
    /// before the turn's commit in 18 of 40 switches (aws-m4pro-7, macOS 26.7, 120 Hz: commit 17.8 ms after the key
    /// against 5.3 ms, first frame 49 to 66 ms against 16 to 25 ms).
    @Test func aPageSwitchedToInItsPaneOrdersItsWindowInOnlyAfterTheFrame() throws {
        let (runtime, root) = try FocusSpyShim.runtime()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tab, host) = try createdTab(runtime, browser: 23)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        try #require(window.contentView).addSubview(tab.contentView)
        Self.endTurn()
        let log = CallLog()
        let fork = CEFLayerHosting.Fork(setLayerHosting: { _, on in on ? 7 : 0 }, setResizeSync: { _, _ in true },
                                        setDetachedHosting: { _, on in log.items.append(on ? "detach" : "attach"); return true })
        let hosting = host.hostView.layerHosting
        hosting.holdsFocus = { false }
        hosting.pageWindowCreated(browser: 23, fork: fork)
        let hosted = Date().addingTimeInterval(2)
        while hosting.page == nil, Date() < hosted { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        try #require(hosting.page != nil)
        // Another tab of the pane shows: this page parks hidden in the page area and the lifecycle conceals it.
        tab.contentView.isHidden = true
        tab.setContentVisible(false)
        Self.endTurn()
        try #require(host.hostView.isHidden, "a parked page's host is hidden by the end of the turn")
        // The page that shows now: its window still fills the pane's page area in the turn of the switch back.
        let leaving = pageWindow(over: tab, in: window)
        leaving.isReleasedWhenClosed = false
        defer { leaving.closeAfterTest() }
        log.items = []
        FocusSpyShim.granted = []
        FocusSpyShim.onGrant = { log.items.append("grant") }
        defer { FocusSpyShim.onGrant = nil }

        // The switch's turn, in the pane's order (`PaneController.showSelected`): bind, reveal, focus.
        tab.contentView.isHidden = false
        tab.setContentVisible(true)
        tab.setFocused(true)
        #expect(!host.hostView.isHidden)
        #expect(log.items == ["detach"], "a page switched to must stay out of the window until its frame showed: \(log.items)")
        window.removeChildWindow(leaving)
        let frames = FrameScheduler.forWindow(window)
        let deadline = Date().addingTimeInterval(2)
        while FocusSpyShim.granted.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            frames.frameDidFire()
        }
        #expect(log.items == ["detach", "attach", "grant"], "the page attaches after the frame and takes the focus after the attach: \(log.items)")
        #expect(!hosting.isDetached)
    }

    private func createdTab(_ runtime: CEFRuntime, browser: Int32) throws -> (CEFTab, CEFPaneHost) {
        let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
        let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
        // A pane host has an area: the fork orders an empty host's page window out, and an empty host takes no focus.
        tab.contentView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.add(tab)
        host.ensureCreated(tab)
        let request = try #require(runtime.pendingWindows.keys.first)
        runtime.handle(.afterCreated(browser: browser, request: request, window: 1))
        #expect(tab.browserID == browser)
        FocusSpyShim.granted = []
        return (tab, host)
    }
}

/// The app's key window in a test: every change a grant makes is recorded.
/// Fork and grant calls in the order they came.
private final class CallLog {
    var items: [String] = []
}

@MainActor private final class KeyRecorder {
    var key: NSWindow?
    private(set) var made: [NSWindow] = []

    init(key: NSWindow?) { self.key = key }

    var seam: CEFKeyWindows {
        CEFKeyWindows(keyWindow: { [unowned self] in key }, makeKey: { [unowned self] window in
            key = window
            made.append(window)
        })
    }
}

/// A view that runs `onHide` when an ancestor hides it.
private final class HideSpyView: NSView {
    var onHide: (() -> Void)?

    override func viewDidHide() {
        super.viewDidHide()
        onHide?()
    }
}

/// Stand-in shim functions: `cmux_shim_set_focus` records the browsers given focus,
/// `cmux_shim_create_window` reports the browser started; every other function does nothing.
private nonisolated enum FocusSpyShim {
    nonisolated(unsafe) static var granted: [Int32] = []
    /// Runs inside a grant (CEF's SetFocus), as a page window becoming key would.
    nonisolated(unsafe) static var onGrant: (() -> Void)?
    /// Tabs hold their runtime unowned and may outlive a test's locals: every runtime lives on.
    @MainActor static var runtimes: [CEFRuntime] = []

    @MainActor static func runtime() throws -> (CEFRuntime, URL) {
        granted = []
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-focus-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try library(), storage: CEFProfileStorage(root: root))
        runtimes.append(runtime)
        return (runtime, root)
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let setFocus: @convention(c) (Int32, Int32) -> Void = { browser, focused in
            if focused == 1 { FocusSpyShim.granted.append(browser); FocusSpyShim.onGrant?() }
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_set_focus": unsafeBitCast(setFocus, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
