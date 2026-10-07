import Testing
@testable import CmuxNextBrowser

@MainActor @Suite(.timeLimit(.minutes(1))) struct CEFReplyWaitersTests {
    /// A DevTools result that never arrives (hover preview, snapshot,
    /// occlusion, script) used to hang its caller forever.
    @Test func missingReplyTimesOut() async {
        let waiters = CEFReplyWaiters<Int, String>()
        await #expect(throws: BrowserTabError.timedOut("probe")) {
            try await waiters.reply(for: 1, timeout: .milliseconds(20)) { BrowserTabError.timedOut("probe") }
        }
        #expect(waiters.count == 0)
        #expect(!waiters.resolve(1, with: .success("late")))
    }

    @Test func replyResolvesItsKeyAndFailAllMatches() async throws {
        let waiters = CEFReplyWaiters<Int, String>()
        let first = Task { try await waiters.reply(for: 1, timeout: .seconds(30)) { BrowserTabError.timedOut("1") } }
        let second = Task { try await waiters.reply(for: 2, timeout: .seconds(30)) { BrowserTabError.timedOut("2") } }
        while waiters.count < 2 { await Task.yield() }
        #expect(waiters.resolve(1, with: .success("one")))
        waiters.failAll(where: { $0 == 2 }, with: BrowserTabError.closed)
        #expect(try await first.value == "one")
        await #expect(throws: BrowserTabError.closed) { try await second.value }
    }
}
