#if DEBUG
import AppKit
import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo, 2026-11-01, on "The agent pane crashed. [Reload]" over 19 chats: "how come it says this???
/// why doens't it just retry on its own", then "i had to close and reopen". A page whose web
/// content ended loads again by itself in a new process, at once on screen and when shown in the
/// background; only a page that keeps ending (3 retries in 60 s) shows the notice. The ends here
/// are injected, no real kill.
@Suite(.serialized)
@MainActor
struct AgentPageCrashRetryTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The backoff waits a test runs itself.
    @MainActor private final class Waits {
        var pending: [(delay: TimeInterval, body: @MainActor () -> Void)] = []
        func runAll() {
            let due = pending
            pending = []
            for wait in due { wait.body() }
        }
    }

    private static func chat(_ session: String, shown: Bool, waits: Waits, clock: @escaping () -> Date = Date.init) throws -> AgentPaneView {
        let file = try #require(AgentPageTestRoot.page)
        let terminations = AgentPageTerminations()
        terminations.afterTurn = { _ in }
        terminations.writeMarker = { _, _, _ in }
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: session), source: .bundled(file),
                                              pageHost: true, testRoot: true, chromium: nil, terminations: terminations))
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.crashRetry.nobodySees = { _ in !shown }
        view.crashRetry.after = { delay, body in waits.pending.append((delay, body)) }
        view.crashRetry.now = clock
        return view
    }

    @Test func theBudgetRetriesThreeTimesWithBackoffThenShowsTheNotice() {
        var budget = AgentPageCrashBudget()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(budget.ended(at: start) == .retry(delay: 0))
        #expect(budget.ended(at: start + 2) == .retry(delay: 1))
        #expect(budget.ended(at: start + 5) == .retry(delay: 4))
        #expect(budget.ended(at: start + 10) == .notice, "a page that keeps ending retried a fourth time in 60 s")
        #expect(budget.ended(at: start + 61) == .retry(delay: 4), "the window did not slide")
        budget.reset()
        #expect(budget.ended(at: start + 62) == .retry(delay: 0), "the person's Reload did not start a fresh budget")
    }

    /// A chat on screen: no notice, and once its backoff passed it loads again in a new WebKit
    /// process (a load, not a reload of a view with no URL).
    @Test func aChatOnScreenLoadsAgainByItself() throws {
        let waits = Waits()
        let chat = try Self.chat("s-shown", shown: true, waits: waits)
        let page = try #require(chat.page)
        page.webContentEnded(PageTermination(reason: .unknown))
        #expect(!chat.showsCrashNotice, "the notice showed instead of a retry")
        #expect(chat.crashRetry.owed && waits.pending.map(\.delay) == [0])
        waits.runAll()
        #expect(chat.crashRetry.count == 1, "the chat did not load again")
        #expect(!chat.crashRetry.owed)
        #expect(page.webKitView.url != nil, "the retry started no load")
        #expect(chat.crashReloadCount == 0, "an automatic retry counted as the person's Reload")
        page.close()
    }

    /// A background chat waits to be shown: 19 chats ending together do not start 19 processes.
    @Test func aBackgroundChatRetriesWhenShown() throws {
        let waits = Waits()
        var shown = false
        let chat = try Self.chat("s-hidden", shown: false, waits: waits)
        chat.crashRetry.nobodySees = { _ in !shown }
        let page = try #require(chat.page)
        page.webContentEnded(PageTermination(reason: .unknown))
        waits.runAll()
        #expect(chat.crashRetry.owed && chat.crashRetry.count == 0, "a chat nobody sees loaded again")
        #expect(!chat.showsCrashNotice)
        shown = true
        chat.crashRetry.runIfShown(chat)
        #expect(chat.crashRetry.count == 1 && !chat.crashRetry.owed, "the shown chat did not load again")
        page.close()
    }

    /// The crash-loop guard: three retries in 60 s, then the notice with Reload, which starts a
    /// fresh budget.
    @Test func aChatThatKeepsEndingShowsTheNotice() throws {
        let waits = Waits()
        var now = Date(timeIntervalSince1970: 5_000)
        let chat = try Self.chat("s-loop", shown: true, waits: waits, clock: { now })
        let page = try #require(chat.page)
        for retry in 1...AgentPageCrashBudget.limit {
            page.webContentEnded(PageTermination(reason: .crash))
            waits.runAll()
            #expect(chat.crashRetry.count == retry && !chat.showsCrashNotice)
            now += 5
        }
        page.webContentEnded(PageTermination(reason: .crash))
        #expect(chat.showsCrashNotice, "a crash loop never showed the notice")
        #expect(!chat.crashRetry.owed && waits.pending.isEmpty)

        #expect(chat.debugPressCrashNoticeReload())
        #expect(!chat.showsCrashNotice && chat.crashReloadCount == 1)
        page.webContentEnded(PageTermination(reason: .crash))
        #expect(!chat.showsCrashNotice && chat.crashRetry.owed, "the person's Reload left no retries")
        page.close()
    }

    /// A page that loaded again before its owed retry ran (a host route, a retarget) is not
    /// reloaded over a live chat; a closed chat is not either.
    @Test func aChatThatCameBackOrClosedIsNotRetried() throws {
        let waits = Waits()
        let back = try Self.chat("s-back", shown: true, waits: waits)
        let closed = try Self.chat("s-closed", shown: true, waits: waits)
        let backPage = try #require(back.page)
        backPage.webContentEnded(PageTermination(reason: .crash))
        try #require(closed.page).webContentEnded(PageTermination(reason: .crash))
        backPage.webView(backPage.webKitView, didFinish: nil)
        closed.close()
        waits.runAll()
        #expect(back.crashRetry.count == 0, "a chat that came back was reloaded")
        #expect(closed.crashRetry.count == 0, "a closed chat was reloaded")
        backPage.close()
    }
}
#endif
