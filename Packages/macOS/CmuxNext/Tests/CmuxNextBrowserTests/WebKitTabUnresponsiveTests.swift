@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing
import WebKit

/// https://github.com/manaflow-ai/cmux/issues/51079: a WebKit tab (open.spotify.com) got stuck and stopped
/// working with no notice. Only Chromium tabs reported a hung page; a WebKit page whose web content process
/// stopped answering kept its last frame and offered no way out. WebKit's own hang report now reaches the tab
/// (the "Page unresponsive" notice), Wait hides it, and Exit page ends the process: the sad tab with Reload.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct WebKitTabUnresponsiveTests {
    @Test func webKitsHangReportShowsTheNoticeAndExitEndsThePage() async throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        try await Self.load(tab)
        let delegate = try #require(tab.webView.navigationDelegate as? NSObject)
        let unresponsive = NSSelectorFromString("_webViewWebProcessDidBecomeUnresponsive:")
        let responsive = NSSelectorFromString("_webViewWebProcessDidBecomeResponsive:")
        // WebKit sends these only to a delegate that answers them (`WKNavigationDelegatePrivate`).
        #expect(delegate.responds(to: unresponsive))
        #expect(delegate.responds(to: responsive))
        #expect((tab as any BrowserTab) is any BrowserHangAnswering)

        delegate.perform(unresponsive, with: tab.webView)
        #expect(tab.state.isUnresponsive)
        delegate.perform(responsive, with: tab.webView)
        #expect(!tab.state.isUnresponsive, "the page answered again and the notice stayed")

        delegate.perform(unresponsive, with: tab.webView)
        tab.answerUnresponsivePage(terminate: false)
        #expect(!tab.state.isUnresponsive, "Wait kept the notice")
        #expect(tab.state.processExit == nil)

        delegate.perform(unresponsive, with: tab.webView)
        tab.answerUnresponsivePage(terminate: true)
        for _ in 0..<600 where tab.state.processExit == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(tab.state.processExit != nil, "Exit page left the hung process running")
        #expect(!tab.state.isUnresponsive)
    }

    /// WebKit reports a hang once; after Wait, a page still hung shows the notice again, one that answers does not.
    @Test func waitLooksAgainAndAPageStillHungShowsTheNoticeAgain() async throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        try await Self.load(tab)
        #expect(tab.webProcessIsResponsive, "a loaded page counted as hung")
        tab.hangRecheckDelay = .milliseconds(20)
        var hung = true
        tab.webProcessIsResponsiveOverride = { !hung }
        tab.webViewWebProcessDidBecomeUnresponsive(tab.webView)
        tab.answerUnresponsivePage(terminate: false)
        #expect(!tab.state.isUnresponsive)
        for _ in 0..<400 where !tab.state.isUnresponsive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tab.state.isUnresponsive, "Wait hid the notice of a page still hung for good")

        hung = false
        tab.answerUnresponsivePage(terminate: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!tab.state.isUnresponsive, "the notice came back for a page that answers")
    }

    @Test func anAnswerWithNoHangDoesNothing() async throws {
        let engine = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory())
        let tab = engine.makeWebKitTab()
        defer { tab.close() }
        try await Self.load(tab)
        tab.answerUnresponsivePage(terminate: true)
        #expect(try await tab.evaluate("6 * 7", world: .page, gesture: .cmux) == .number(42), "Exit ended a page that answered")
        #expect(tab.state.processExit == nil)
    }

    private static func load(_ tab: WebKitTab) async throws {
        tab.webView.loadHTMLString("<!doctype html><title>hang</title><p>hang</p>", baseURL: URL(string: "https://hang.example/"))
        for _ in 0..<600 {
            if (try? await tab.evaluate("document.readyState === 'complete' && document.title === 'hang'", world: .page, gesture: .cmux)) == .bool(true) {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("the page never loaded")
    }
}
