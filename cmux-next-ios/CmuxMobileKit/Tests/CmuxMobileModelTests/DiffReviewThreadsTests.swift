import Foundation
import Testing
@testable import CmuxMobileModel

@Suite struct DiffReviewThreadsTests {
    private func comment(_ id: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["id": id, "filePath": "src/a.rs", "side": "additions", "startLine": 3, "endLine": 4,
                                     "lineText": "x", "message": "why?", "createdAt": "2026-11-28T21:00:00Z",
                                     "updatedAt": "2026-11-28T21:00:0\(id.last!)Z"]
        object.merge(extra) { $1 }
        return object
    }

    /// The daemon's list reply: a thread's replies, resolve and chase marks, stalled first.
    @Test func aListReplyReadsEachThreadsStateInTheOrderToAnswer() throws {
        let reply: [String: Any] = ["ok": true, "result": ["root": "/r", "comments": [
            comment("dc_1"),
            comment("dc_2", ["resolved": true]),
            comment("dc_3", ["sentTo": "c-1", "agentRepliesAtSend": 0, "chases": 2,
                             "replies": [["id": "r1", "author": "reviewer", "text": "and?", "createdAt": "t"]]]),
            comment("dc_4", ["sentTo": "c-1", "agentRepliesAtSend": 0, "chases": 3, "stalled": true]),
            comment("dc_5", ["sentTo": "c-1", "agentRepliesAtSend": 0,
                             "replies": [["id": "r2", "author": "agent", "text": "fixed", "createdAt": "t"]]]),
            ["filePath": "no-id"],
        ]]]
        let threads = DiffReviewThread.threads(fromList: reply)
        #expect(threads.map(\.id) == ["dc_4", "dc_3", "dc_1", "dc_5", "dc_2"])
        #expect(threads.map(\.state) == [.stalled, .awaitingAgent(chases: 2), .open, .open, .resolved])
        let chased = try #require(threads.first { $0.id == "dc_3" })
        #expect(chased.location == "src/a.rs:4")
        #expect(chased.replies.map(\.text) == ["and?"])
        #expect(chased.updatedAt == "2026-11-28T21:00:03Z")
        #expect(chased.sentTo == "c-1")
    }

    /// An agent answer after the send ends the wait, though the thread stays open.
    @Test func anAgentReplyAfterTheSendEndsTheWait() {
        let thread = DiffReviewThread(json: comment("dc_1", ["sentTo": "c-1", "agentRepliesAtSend": 1, "replies": [
            ["id": "a", "author": "agent", "text": "one"], ["id": "b", "author": "reviewer", "text": "more?"],
        ]]))
        #expect(thread?.state == .awaitingAgent(chases: 0))
        var answered = thread
        answered?.replies.append(.init(id: "c", author: "agent", text: "done", createdAt: nil))
        #expect(answered?.state == .open)
    }

    /// Off unless the env or the defaults key turns it on.
    @Test func theFlagIsOffByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "diff-review-threads-\(UUID().uuidString)"))
        #expect(!DiffReviewThreadsFlag(environment: [:], defaults: defaults).isEnabled)
        #expect(DiffReviewThreadsFlag(environment: ["CMUX_DIFF_REVIEW_THREADS": "1"], defaults: defaults).isEnabled)
        defaults.set(true, forKey: DiffReviewThreadsFlag.defaultsKey)
        #expect(DiffReviewThreadsFlag(environment: [:], defaults: defaults).isEnabled)
        #expect(!DiffReviewThreadsFlag(environment: ["CMUX_DIFF_REVIEW_THREADS": "0"], defaults: defaults).isEnabled)
    }

    @MainActor @Test func theCenterOffersNothingWithTheFlagOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "diff-review-threads-\(UUID().uuidString)"))
        let center = DiffReviewThreadsCenter(flag: DiffReviewThreadsFlag(environment: [:], defaults: defaults))
        let backend = StubBackend()
        center.backend = backend
        #expect(!center.isAvailable(on: "mac-1"))
        center.flag = DiffReviewThreadsFlag(environment: ["CMUX_DIFF_REVIEW_THREADS": "1"], defaults: defaults)
        #expect(center.isAvailable(on: "mac-1"))
        #expect(!center.isAvailable(on: ""))
    }
}

@MainActor
private final class StubBackend: DiffReviewThreadsBackend {
    func canReviewThreads(on macID: String) -> Bool { true }
    func reviewThreads(root: String, on macID: String) async throws -> [DiffReviewThread] { [] }
    func reply(_ text: String, to thread: String, root: String, on macID: String) async throws {}
    func setResolved(_ resolved: Bool, thread: String, root: String, on macID: String) async throws {}
    func sendBack(_ threads: [DiffReviewThread], root: String, chat: String, on macID: String) async throws {}
}
