import Foundation
import Testing

@testable import CmuxBrowser

/// A window a page opens from a tab a session created becomes that
/// session's tab, under its content rules and page clipboard guard. The new
/// tab must carry them before it loads anything: a page that loads first
/// could fetch subresources the policy blocks, or write the system clipboard.
@MainActor
@Suite("Browser REPL popup opening")
struct BrowserReplPopupOpeningTests {
    private final class Tab {
        let initialURL: URL?
        init(_ url: URL?) { initialURL = url }
    }

    private final class Log {
        var events: [String] = []
    }

    private func opening(_ log: Log, creates: Bool = true) -> BrowserReplPopupOpening<Tab> {
        BrowserReplPopupOpening(
            create: { url in
                log.events.append("create \(url?.absoluteString ?? "blank")")
                return creates ? Tab(url) : nil
            },
            handOver: { _ in log.events.append("hand over") },
            load: { _, url in log.events.append("load \(url.absoluteString)") }
        )
    }

    @Test("A session's popup opens blank, is handed to the session, and only then loads its URL")
    func sessionPopupLoadsAfterHandOver() throws {
        let log = Log()
        let url = try #require(URL(string: "https://docs.example.com/a"))
        let tab = opening(log).open(url, handOverFirst: true)
        #expect(tab != nil)
        #expect(tab?.initialURL == nil, "the tab was created with its URL, so it loaded before the session's rules were on it")
        #expect(log.events == ["create blank", "hand over", "load https://docs.example.com/a"])
    }

    @Test("Another popup opens with its URL and is then handed over")
    func otherPopupsOpenWithTheirURL() throws {
        let log = Log()
        let url = try #require(URL(string: "https://docs.example.com/a"))
        let tab = opening(log).open(url, handOverFirst: false)
        #expect(tab?.initialURL == url)
        #expect(log.events == ["create https://docs.example.com/a", "hand over"])
    }

    @Test("A tab that could not be created is neither handed over nor loaded")
    func noTabNoLoad() throws {
        let log = Log()
        let url = try #require(URL(string: "https://docs.example.com/a"))
        #expect(opening(log, creates: false).open(url, handOverFirst: true) == nil)
        #expect(log.events == ["create blank"])
    }
}
