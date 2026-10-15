import Foundation
import Testing
@testable import CmuxCEF

/// `CEFReplyWaiters.send`: a DevTools method the browser process answers
/// itself replies inside `ExecuteDevToolsMethod`, before the call returns its
/// message id. That reply must reach the caller, not wait out the timeout.
@MainActor
@Suite struct CEFReplyWaitersTests {
    struct Late: Error {}
    struct Closed: Error {}

    /// A reply delivered while `start` runs (synchronous answer) is returned.
    @Test func replyInsideStartIsReturned() async throws {
        let waiters = CEFReplyWaiters<Int, String>()
        let value = try await waiters.send(timeout: .seconds(3600), notStarted: Closed(), timeoutError: { Late() }) {
            waiters.resolve(7, with: .success("{\"ok\":true}"))
            return 7
        }
        #expect(value == "{\"ok\":true}")
        #expect(waiters.count == 0)
    }

    /// A failure delivered while `start` runs is thrown as is.
    @Test func failureInsideStartIsThrown() async {
        let waiters = CEFReplyWaiters<Int, String>()
        await #expect(throws: CEFError.self) {
            try await waiters.send(timeout: .seconds(3600), notStarted: Closed(), timeoutError: { Late() }) {
                waiters.resolve(3, with: .failure(CEFError.devTools("nope")))
                return 3
            }
        }
    }

    /// A reply after `start` returned still resolves the waiter.
    @Test func replyAfterStartResolvesTheWaiter() async throws {
        let waiters = CEFReplyWaiters<Int, String>()
        async let value = waiters.send(timeout: .seconds(3600), notStarted: Closed(), timeoutError: { Late() }) { 9 }
        while waiters.count == 0 { await Task.yield() }
        #expect(waiters.resolve(9, with: .success("later")))
        #expect(try await value == "later")
    }

    /// A request that could not be made throws `notStarted`.
    @Test func noKeyThrowsNotStarted() async {
        let waiters = CEFReplyWaiters<Int, String>()
        await #expect(throws: Closed.self) {
            try await waiters.send(timeout: .seconds(3600), notStarted: Closed(), timeoutError: { Late() }) { nil }
        }
    }

    /// Outside a `send`, a reply nobody waits for is still dropped, and an
    /// early reply for another key is not kept past the send.
    @Test func strayRepliesAreNotKept() async throws {
        let waiters = CEFReplyWaiters<Int, String>()
        #expect(!waiters.resolve(1, with: .success("stray")))
        _ = try await waiters.send(timeout: .seconds(3600), notStarted: Closed(), timeoutError: { Late() }) {
            waiters.resolve(2, with: .success("other"))
            waiters.resolve(4, with: .success("mine"))
            return 4
        }
        async let value = waiters.send(timeout: .seconds(3600), notStarted: Closed(), timeoutError: { Late() }) { 2 }
        while waiters.count == 0 { await Task.yield() }
        #expect(waiters.resolve(2, with: .success("fresh")))
        #expect(try await value == "fresh")
    }
}
