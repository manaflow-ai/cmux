import AppKit
import Testing
@testable import CmuxNextBrowser

/// A tab restored at launch reloads its page; that load is not a new visit
/// (plans/cmux-next/history.md 2, `page`). Seen on tag nxhist: every relaunch
/// added one more "Example Domain" visit.
@MainActor
struct RestoredVisitTests {
    static func finished(_ url: String, title: String) -> BrowserTabState {
        var state = BrowserTabState(url: URL(string: url), title: title)
        state.phase = .finished
        return state
    }

    @Test func aRestoredPageLoadIsNotAVisitButLaterNavigationsAre() {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        let chrome = BrowserChromeView(tab: tab)
        let history = InMemoryBrowserHistory()
        chrome.history = history
        chrome.markRestored(URL(string: "https://example.com/"))
        chrome.recordHistory(Self.finished("https://example.com/", title: "Example"))
        #expect(history.entries.isEmpty)
        chrome.recordHistory(Self.finished("https://example.org/next", title: "Next"))
        #expect(history.entries.map(\.url.absoluteString) == ["https://example.org/next"])
    }
}
