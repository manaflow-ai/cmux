#if DEBUG
import AppKit
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cmux issue 28710: a WebContent process that served 5 agent chats ended (after the WebKit GPU
/// process crashed), all 5 showed "The agent pane crashed." in the same 100 ms, and cmux logged
/// only "agent pane web content ended" with no reason, pid or page. Each Reload reloaded only its
/// own chat. The ends here are injected (WebKit's delegate calls with a reason), no real kill.
@Suite(.serialized)
@MainActor
struct AgentPageTerminationsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private final class Markers {
        var written: [[String: Any]] = []
    }

    /// The app's record of page ends, with the end-of-turn report run by the test
    /// (``AgentPageTerminations/endTurn()``) and the markers kept in memory.
    private static func terminations(_ markers: Markers) -> AgentPageTerminations {
        let terminations = AgentPageTerminations()
        terminations.afterTurn = { _ in }
        terminations.writeMarker = { json, _, _ in
            if let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] { markers.written.append(object) }
        }
        return terminations
    }

    private static func chat(_ session: String, file: URL, pageHost: Bool = false,
                             terminations: AgentPageTerminations) throws -> AgentPaneView {
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: session), source: .bundled(file),
                                              pageHost: pageHost, testRoot: pageHost, chromium: nil, terminations: terminations))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        // These chats kept ending: their retries are spent, so the next end shows the notice
        // (AgentPageCrashRetryTests covers the retries).
        for _ in 0..<AgentPageCrashBudget.limit { _ = view.crashRetry.budget.ended(at: Date()) }
        return view
    }

    private static func pageFile() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-page-terminations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "index.html")
        try Data("<html></html>".utf8).write(to: file)
        return (file, { try? FileManager.default.removeItem(at: directory) })
    }

    /// The pane's own WebKit host (the default): WebKit's reason SPI reaches the pane; the pages
    /// that ended in one turn form one event with the reason, pid and count, written as one marker;
    /// one Reload reloads both, and neither the chat that did not crash nor the one that ended in
    /// another termination.
    @Test func oneReloadReloadsEveryChatThatEndedWithIt() throws {
        let (file, cleanup) = try Self.pageFile()
        defer { cleanup() }
        let markers = Markers()
        let terminations = Self.terminations(markers)

        let first = try Self.chat("s-first", file: file, terminations: terminations)
        let second = try Self.chat("s-second", file: file, terminations: terminations)
        let untouched = try Self.chat("s-untouched", file: file, terminations: terminations)
        let other = try Self.chat("s-other", file: file, terminations: terminations)
        // The pid each page saw at its last load: WebKit reports 0 for a process that ended.
        first.knownWebContentPid = 48_637
        second.knownWebContentPid = 48_637

        // WebKit tells the first page of the ended process with its reason (3: Crash) and no pid,
        // then its sibling in the same process.
        first.webContentProcessDidTerminate(PageTermination(reason: PageTermination.Reason(webKit: 3), pid: 0))
        second.webContentProcessDidTerminate(PageTermination(reason: .crash, pid: 0))
        let event = try #require(terminations.event(of: first))
        #expect(event === terminations.event(of: second), "two chats of one ended process are two terminations")
        #expect(event.reason == .crash, "WebKit's reason was not kept")
        #expect(event.pid == 48_637, "the ended process's pid was not kept")
        #expect(event.pages.map(\.session) == ["s-first", "s-second"])
        #expect(first.showsCrashNotice && second.showsCrashNotice)

        // The turn ends: one marker for the group.
        terminations.endTurn()
        let marker = try #require(markers.written.first, "no crash marker for the ended group")
        #expect(markers.written.count == 1)
        #expect(marker["kind"] as? String == "webkit")
        #expect(marker["host"] as? String == "agent-page")
        #expect(marker["reason"] as? String == "crash")
        #expect(marker["pages_ended"] as? Int == 2)
        #expect((marker["pid"] as? Int).map(Int32.init) == event.pid)
        let sessions = (marker["pages"] as? [[String: String]])?.compactMap { $0["session"] }
        #expect(sessions == ["s-first", "s-second"])

        // Another process ends later, for another reason: its own event.
        other.webContentProcessDidTerminate(PageTermination(reason: .memoryLimit, pid: 51_002))
        terminations.endTurn()
        #expect(terminations.event(of: other) !== event)
        #expect(markers.written.last?["reason"] as? String == "memory-limit")

        // Nothing reloaded by itself.
        #expect([first, second, untouched, other].allSatisfy { $0.crashReloadCount == 0 })

        // The person presses Reload in the first chat: both chats of its termination reload.
        #expect(first.debugPressCrashNoticeReload())
        #expect(!first.showsCrashNotice && !second.showsCrashNotice, "the sibling chat still shows the notice")
        #expect(first.crashReloadCount == 1 && second.crashReloadCount == 1, "the sibling chat was not reloaded")
        #expect(untouched.crashReloadCount == 0 && !untouched.showsCrashNotice, "a chat that did not crash was reloaded")
        #expect(other.crashReloadCount == 0 && other.showsCrashNotice, "a chat of another termination was reloaded")
        #expect(terminations.event(of: first) == nil)

        // Its own Reload still reloads only it.
        #expect(other.debugPressCrashNoticeReload())
        #expect(other.crashReloadCount == 1 && first.crashReloadCount == 1)
    }

    /// WebKit's reason SPI on the pane's navigation delegate reaches the record with the reason.
    @Test func webKitsReasonReachesTheRecord() throws {
        let (file, cleanup) = try Self.pageFile()
        defer { cleanup() }
        let terminations = Self.terminations(Markers())
        let chat = try Self.chat("s-reason", file: file, terminations: terminations)
        let navigation = try #require(chat.webView.navigationDelegate as? AgentPaneNavigation)
        navigation.webView(chat.webView, webContentProcessDidTerminateWithReason: 0)
        #expect(terminations.event(of: chat)?.reason == .memoryLimit)
        #expect(chat.showsCrashNotice && chat.crashReloadCount == 0)
    }

    /// The user's report (2026-10-30, "i see agent pane crashed but it looks fine"): the notice
    /// stayed over a chat that was live again. Nothing but the person's Reload took it away, so a
    /// page that loaded a document again after the end (the host opened a route, a pooled page was
    /// retargeted, Chromium fell back to WebKit and loaded) kept "The agent pane crashed." on top of
    /// a working chat. A finished document load is proof the page lives: the notice goes, the chat
    /// leaves its crash group, and nothing reloads it.
    @Test func aChatThatLoadsAgainDropsTheNotice() throws {
        let (file, cleanup) = try Self.pageFile()
        defer { cleanup() }
        let terminations = Self.terminations(Markers())
        let live = try Self.chat("s-live", file: file, terminations: terminations)
        let dead = try Self.chat("s-dead", file: file, terminations: terminations)
        live.webContentProcessDidTerminate(PageTermination(reason: .crash, pid: 80_001))
        dead.webContentProcessDidTerminate(PageTermination(reason: .crash, pid: 80_001))
        #expect(live.showsCrashNotice && dead.showsCrashNotice)

        let navigation = try #require(live.webView.navigationDelegate as? AgentPaneNavigation)
        navigation.webView(live.webView, didFinish: nil)
        #expect(!live.showsCrashNotice, "the notice stayed over a chat whose page loaded again")
        #expect(terminations.event(of: live) == nil, "a live chat stayed in its crash group")
        #expect(live.crashReloadCount == 0, "a chat that recovered was reloaded")
        #expect(dead.showsCrashNotice, "a chat that did not load again lost its notice")

        // The sibling's Reload no longer reloads the chat that came back by itself.
        #expect(dead.debugPressCrashNoticeReload())
        #expect(live.crashReloadCount == 0 && dead.crashReloadCount == 1)
    }

    /// The same on the shared page host: the page finished a document after its end (either
    /// engine reports it through ``PageWebView/documentFinished()``), so its pane drops the notice.
    @Test func aPageHostChatThatLoadsAgainDropsTheNotice() throws {
        let file = try #require(AgentPageTestRoot.page)
        let terminations = Self.terminations(Markers())
        let chat = try Self.chat("s-page-live", file: file, pageHost: true, terminations: terminations)
        let page = try #require(chat.page)
        page.webContentEnded(PageTermination(reason: .crash, pid: 80_002))
        #expect(chat.showsCrashNotice)
        page.webView(page.webKitView, didFinish: nil)
        #expect(!chat.showsCrashNotice, "the notice stayed over a page host chat that loaded again")
        #expect(terminations.event(of: chat) == nil)
        #expect(chat.crashReloadCount == 0)
        page.close()
    }

    /// A chat closed while its crash group waits is not reloaded by a sibling's Reload.
    @Test func aClosedChatLeavesItsGroup() throws {
        let (file, cleanup) = try Self.pageFile()
        defer { cleanup() }
        let terminations = Self.terminations(Markers())
        let first = try Self.chat("s-close-first", file: file, terminations: terminations)
        let closed = try Self.chat("s-close-closed", file: file, terminations: terminations)
        first.webContentProcessDidTerminate(PageTermination(reason: .crash, pid: 70_001))
        closed.webContentProcessDidTerminate(PageTermination(reason: .crash, pid: 70_001))
        closed.close()
        #expect(terminations.event(of: closed) == nil)
        #expect(first.debugPressCrashNoticeReload())
        #expect(first.crashReloadCount == 1 && closed.crashReloadCount == 0, "a closed chat was reloaded")
    }

    /// The shared page host (`agent.pageHost`): the page keeps WebKit's reason and pid for the pane,
    /// and the pane's Reload reloads its sibling's page too.
    @Test func thePageHostReportsTheReasonAndReloadsTheGroup() throws {
        let file = try #require(AgentPageTestRoot.page)
        let markers = Markers()
        let terminations = Self.terminations(markers)

        let first = try Self.chat("s-page-first", file: file, pageHost: true, terminations: terminations)
        let second = try Self.chat("s-page-second", file: file, pageHost: true, terminations: terminations)
        let firstPage = try #require(first.page)
        let secondPage = try #require(second.page)
        #expect(!firstPage.reloadsAfterCrash)

        firstPage.webContentEnded(PageTermination(reason: .crash, pid: 61_337))
        secondPage.webContentEnded(PageTermination(reason: .crash, pid: 61_337))
        #expect(firstPage.lastTermination == PageTermination(reason: .crash, pid: 61_337))
        let event = try #require(terminations.event(of: first))
        #expect(event === terminations.event(of: second))
        #expect(event.pid == 61_337 && event.reason == .crash)
        #expect(first.showsCrashNotice && second.showsCrashNotice)
        terminations.endTurn()
        #expect(markers.written.last?["pid"] as? Int == 61_337)

        #expect(second.debugPressCrashNoticeReload())
        #expect(first.crashReloadCount == 1 && second.crashReloadCount == 1)
        #expect(!first.showsCrashNotice && !second.showsCrashNotice)
        firstPage.close()
        secondPage.close()
    }
}
#endif
