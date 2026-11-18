@testable import CmuxNextBrowser
import Foundation
import Testing

/// A page whose close never resolves (a hung renderer: no "Leave site?" question, never gone) kept its tab in
/// ``PageClosingTabs`` for good, so every later Cmd-W skipped that tab and closed the next one (cmux-b6 review of the
/// Cmd-W burst, PageClosingTabs.swift:21). The set now holds a tab for ``PageClosingTabs/limit`` at most.
@MainActor @Suite struct PageClosingTabsBoundTests {
    final class Clock { var now = ContinuousClock.now }

    static func page() -> MockBrowserTab {
        MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
    }

    @Test func aPageThatNeverDecidesLeavesTheSetAfterTheLimit() {
        let clock = Clock()
        let closing = PageClosingTabs(now: { clock.now })
        let page = Self.page()
        closing.begin("t1", page: page)
        #expect(closing.contains("t1"), "a tab whose page decides is closing")
        clock.now = clock.now.advanced(by: PageClosingTabs.limit - .milliseconds(1))
        #expect(closing.contains("t1"), "still within the limit")
        clock.now = clock.now.advanced(by: .milliseconds(2))
        #expect(!closing.contains("t1"), "a page that never decided kept its tab closing past the limit")
        _ = page
    }

    @Test func aNewBeginStartsANewLimit() {
        let clock = Clock()
        let closing = PageClosingTabs(now: { clock.now })
        let page = Self.page()
        closing.begin("t1", page: page)
        clock.now = clock.now.advanced(by: PageClosingTabs.limit + .milliseconds(1))
        closing.begin("t1", page: page)
        #expect(closing.contains("t1"))
        closing.end("t1")
        #expect(!closing.contains("t1"))
    }
}
