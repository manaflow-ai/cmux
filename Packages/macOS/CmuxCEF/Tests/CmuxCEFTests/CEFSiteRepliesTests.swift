import Foundation
import Testing
@testable import CmuxCEF

@Suite("CEF site replies") @MainActor
struct CEFSiteRepliesTests {
    /// A fake runtime: availability is settable; events go to the observer.
    final class Fake {
        var reason: CEFUnavailableReason?
        var observer: (@MainActor (CEFShimEvent) -> Void)?
    }

    private func make(_ fake: Fake) -> CEFSiteReplies {
        CEFSiteReplies(environment: .init(
            unavailableReason: { fake.reason },
            observe: { fake.observer = $0 }
        ))
    }

    @Test func aReplyDuringTheShimCallIsReturnedAtOnce() async throws {
        let fake = Fake()
        let replies = make(fake)
        let reply = try await replies.call(label: "t", timeout: .seconds(60)) { id in
            fake.observer?(.reply(browser: 0, id: id, value: 3, json: #"{"written":3}"#))
            return 1
        }
        #expect(reply == CEFSiteReplies.Reply(value: 3, json: #"{"written":3}"#))
        #expect(replies.waitingCount == 0)
    }

    @Test func aLaterReplyResolvesTheWaiterAndOtherIdsAreIgnored() async throws {
        let fake = Fake()
        let replies = make(fake)
        var started: Int32 = 0
        let task = Task { @MainActor in
            try await replies.call(label: "t", timeout: .seconds(60)) { id in
                started = id
                return 1
            }
        }
        for _ in 0..<20 where replies.waitingCount == 0 {
            await Task.yield()
        }
        fake.observer?(.reply(browser: 0, id: started + 100, value: 9, json: "{}"))
        fake.observer?(.reply(browser: 0, id: started, value: 1, json: "{}"))
        #expect(try await task.value.value == 1)
    }

    @Test func shutdownFailsWaitingCallsAtOnce() async {
        let fake = Fake()
        let replies = make(fake)
        let task = Task { @MainActor in
            try await replies.call(label: "t", timeout: .seconds(60)) { _ in 1 }
        }
        for _ in 0..<20 where replies.waitingCount == 0 {
            await Task.yield()
        }
        replies.failAll()
        await #expect(throws: CEFError.browserClosed) { try await task.value }
    }

    @Test func callsAreRefusedWhileChromiumIsUnavailableOrShuttingDown() async {
        let fake = Fake()
        let replies = make(fake)
        fake.reason = .shutDown
        var started = false
        await #expect(throws: CEFError.unavailable(.shutDown)) {
            try await replies.call(label: "t", timeout: .seconds(60)) { _ in
                started = true
                return 1
            }
        }
        #expect(!started)
    }

    @Test func aCallThatDidNotStartFailsWithoutWaiting() async {
        let replies = make(Fake())
        await #expect(throws: CEFError.browserClosed) {
            try await replies.call(label: "t", timeout: .seconds(60)) { _ in 0 }
        }
        #expect(replies.waitingCount == 0)
    }
}
