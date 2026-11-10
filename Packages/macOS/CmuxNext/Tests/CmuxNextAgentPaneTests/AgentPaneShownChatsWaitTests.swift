import AppKit
@testable import CmuxNextAgentPane
import CmuxNextWakeupsTestSupport
import Testing

/// The launch spare's hold on the restored chats on screen (AgentPaneShownChatsWait): it ends once, when the last
/// page drew or at the deadline, and a page that drew already holds nothing.
@MainActor @Suite struct AgentPaneShownChatsWaitTests {
    /// `count` stand-in pages; `paint(i)` is page i drawing. `ended` counts the wait's `then`.
    private final class Pages {
        var waiters: [() -> Void] = []
        var ended = 0
        let count: Int
        init(_ count: Int) { self.count = count }
        var loading: [AgentPaneShownChatsWait.WhenPainted] { (0..<count).map { _ in { self.waiters.append($0) } } }
        func paint(_ index: Int) { waiters[index]() }
        func ask(_ wait: AgentPaneShownChatsWait) -> Bool { wait.holds({ loading }, then: { self.ended += 1 }) }
    }

    @Test func holdsUntilTheLastShownChatDrewThenEndsOnce() {
        let wait = AgentPaneShownChatsWait()
        let pages = Pages(2)
        let first = pages.ask(wait), again = pages.ask(wait)
        #expect(first)
        #expect(again, "a second ask while waiting still holds")
        pages.paint(0)
        #expect(pages.ended == 0)
        pages.paint(1)
        #expect(pages.ended == 1)
        pages.paint(1)
        #expect(pages.ended == 1, "a later paint report ended it again")
        let after = pages.ask(wait)
        #expect(!after, "the run's one check is spent")
    }

    @Test func noShownChatLoadingHoldsNothing() {
        let pages = Pages(0)
        let held = pages.ask(AgentPaneShownChatsWait())
        #expect(!held)
        #expect(pages.ended == 0, "nothing waited, nothing ends")
    }

    @Test func aPageThatDrewWhileAskedHoldsNothing() {
        let wait = AgentPaneShownChatsWait()
        var ended = 0
        let held = wait.holds({ [{ $0() }] }, then: { ended += 1 })
        #expect(!held)
        #expect(ended == 0, "the caller goes on itself; the wait must not also run `then`")
    }

    @Test func aPageThatNeverDrawsHoldsOnlyUntilTheDeadline() async throws {
        // The deadline runs on a clock the test moves, not on the wall clock (test determinism gate).
        let clock = ManualClock()
        let wait = AgentPaneShownChatsWait(clock: clock)
        let pages = Pages(1)
        let held = pages.ask(wait)
        #expect(held)
        try await clock.waitForSleeper()
        clock.advance(by: AgentPaneShownChatsWait.deadline - .milliseconds(1))
        #expect(pages.ended == 0, "the wait ended before its deadline")
        clock.advance(by: .milliseconds(1))
        await Self.until { pages.ended == 1 }
        #expect(pages.ended == 1)
        pages.paint(0)
        #expect(pages.ended == 1, "the paint after the deadline ended it again")
    }

    /// Waits for the deadline's main-actor step, which runs after the clock moved; bounded by a deadline, not a
    /// yield count.
    private static func until(_ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition(), clock.now < deadline { await Task.yield() }
    }
}

/// Only a window the person can see counts (review of #39700, F1): a page in a window that is ordered out or has
/// none holds no spare.
@MainActor @Suite struct AgentPaneShownChatsWindowTests {
    @Test func aWindowOrderedOutOrMissingIsNotShown() {
        #expect(!AgentPaneShownChatsWait.shown(nil))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(!AgentPaneShownChatsWait.shown(window), "a window never ordered in counted as shown")
    }
}
