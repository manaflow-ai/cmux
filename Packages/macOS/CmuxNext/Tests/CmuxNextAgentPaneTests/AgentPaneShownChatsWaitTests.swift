@testable import CmuxNextAgentPane
import Testing

/// The launch spare's hold on the restored chats on screen (AgentPaneShownChatsWait): it ends once, when the last
/// page drew or at the deadline, and a page that drew already holds nothing.
@MainActor @Suite struct AgentPaneShownChatsWaitTests {
    /// `count` stand-in pages; `paint(i)` is page i drawing.
    private final class Pages {
        var waiters: [() -> Void] = []
        let count: Int
        init(_ count: Int) { self.count = count }
        var loading: [AgentPaneShownChatsWait.WhenPainted] { (0..<count).map { _ in { self.waiters.append($0) } } }
        func paint(_ index: Int) { waiters[index]() }
    }

    @Test func holdsUntilTheLastShownChatDrewThenEndsOnce() {
        let wait = AgentPaneShownChatsWait()
        let pages = Pages(2)
        var ended = 0
        #expect(wait.holds({ pages.loading }, then: { ended += 1 }))
        #expect(wait.holds({ pages.loading }, then: { ended += 1 }), "a second ask while waiting still holds")
        pages.paint(0)
        #expect(ended == 0)
        pages.paint(1)
        #expect(ended == 1)
        pages.paint(1)
        #expect(ended == 1, "a later paint report ended it again")
        #expect(!wait.holds({ pages.loading }, then: { ended += 1 }), "the run's one check is spent")
    }

    @Test func noShownChatLoadingHoldsNothing() {
        let wait = AgentPaneShownChatsWait()
        #expect(!wait.holds({ [] }, then: { Issue.record("nothing waited, nothing ends") }))
    }

    @Test func aPageThatDrewWhileAskedHoldsNothing() {
        let wait = AgentPaneShownChatsWait()
        var ended = 0
        #expect(!wait.holds({ [{ $0() }] }, then: { ended += 1 }))
        #expect(ended == 0, "the caller goes on itself; the wait must not also run `then`")
    }

    @Test func aPageThatNeverDrawsHoldsOnlyUntilTheDeadline() async throws {
        let wait = AgentPaneShownChatsWait()
        let pages = Pages(1)
        var ended = 0
        #expect(wait.holds({ pages.loading }, then: { ended += 1 }))
        try await Task.sleep(for: AgentPaneShownChatsWait.deadline + .milliseconds(500))
        #expect(ended == 1)
        pages.paint(0)
        #expect(ended == 1, "the paint after the deadline ended it again")
    }
}
