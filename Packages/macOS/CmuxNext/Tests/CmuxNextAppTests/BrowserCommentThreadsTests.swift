import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextDiff

/// Browser comments go back to the agent as threads (cmuxterm-hq goals/all-surface-comments-round-trip.md):
/// one action saves a design mode comment as `surface: "browser"` and sends it to the chat in a
/// threaded send; the thread shows "Sent", then the agent's reply in the thread from
/// `diff.comments.list`; Resolve
/// deletes it. A send needs a real click or key, and a host without threads keeps the chip path.
@MainActor
@Suite(.serialized)
struct BrowserCommentThreadsTests {
    /// The session host's `diff.comments.*` with `diff-comments-threads-v1`, in memory.
    final class ThreadingHost: DiffCommentsStoring {
        var comments: [String: [JSONValue]] = [:]
        var keys: [String] = []
        var supportsCommentThreads = true
        /// Each `diff.comments.send {threads: true}`: its acpmux session, ids, note and key.
        var sends: [(session: String, ids: [String], text: String?, key: String)] = []
        var lists = 0
        /// The next `diff.comments.send {threads: true}` fails (the chat refused the prompt).
        var refusesSend = false

        func listComments(root: String) async throws(AgentPaneGitFailure) -> JSONValue {
            lists += 1
            return ["root": .string(root), "comments": .array(comments[root] ?? [])]
        }

        func saveComment(root: String, comment: JSONValue, key: String) async throws(AgentPaneGitFailure) -> JSONValue {
            keys.append(key)
            guard case .object(var record) = comment else { throw AgentPaneGitFailure.failed }
            record["id"] = .string("c\((comments[root]?.count ?? 0) + 1)")
            record["updatedAt"] = .number(1)
            comments[root, default: []].append(.object(record))
            return ["comment": .object(record)]
        }

        func deleteComments(root: String, ids: [String], versions: [String: JSONValue], key: String) async throws(AgentPaneGitFailure) -> JSONValue {
            keys.append(key)
            comments[root]?.removeAll { ids.contains($0["id"]?.stringValue ?? "") }
            return ["deleted": .number(Double(ids.count)), "ids": .array(ids.map(JSONValue.string))]
        }

        func postReview(root: String, ids: [String], versions: [String: JSONValue], key: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func sendComments(root: String, acpSession: String, ids: [String], versions: [String: JSONValue],
                          text: String, key: String) async throws(AgentPaneGitFailure) -> JSONValue {
            Issue.record("a browser comment is sent threaded, never cleared")
            throw AgentPaneGitFailure.failed
        }

        func sendThreadedComments(root: String, acpSession: String, ids: [String], text: String?, key: String)
            async throws(AgentPaneGitFailure) -> JSONValue {
            if refusesSend { throw AgentPaneGitFailure.failed }
            sends.append((acpSession, ids, text, key))
            comments[root] = (comments[root] ?? []).map { comment in
                guard case .object(var record) = comment, ids.contains(record["id"]?.stringValue ?? "") else { return comment }
                record["sentIn"] = .string(key)
                return .object(record)
            }
            return ["sent": .number(Double(ids.count)), "cleared": [], "threads": .array(ids.map(JSONValue.string))]
        }

        /// The agent answers in comment `id`'s thread with `reply` (`diff.comments.thread {author: agent}`).
        func answer(_ id: String, root: String, reply: String) {
            comments[root] = (comments[root] ?? []).map { comment in
                guard case .object(var record) = comment, record["id"]?.stringValue == id else { return comment }
                record["replies"] = [["id": "r1", "author": "agent", "text": .string(reply)]]
                return .object(record)
            }
        }
    }

    static let root = "/repo"
    static let comment = BrowserComment(url: "https://example.com/pricing", title: "Pricing", selector: "main > h1",
                                        quote: "Simple pricing", message: "Make this bigger",
                                        prompt: "On https://example.com/pricing, main > h1: Make this bigger")

    @Test func sendSavesABrowserCommentThenSendsItThreadedAndShowsTheReply() async throws {
        let host = ThreadingHost()
        let threads = BrowserCommentThreads(pollInterval: nil)
        var changes: [(String, BrowserCommentThread?)] = []
        threads.onChange = { changes.append(($0, $1)) }

        let thread = try await threads.send(Self.comment, key: "card-1", store: host, root: Self.root, acpSession: "acp-7",
                                            opid: "op-1", userGesture: true)

        // Saved as a browser comment, with the page, the element and what the person wrote.
        let saved = try #require(host.comments[Self.root]?.first)
        #expect(saved["surface"]?.stringValue == "browser")
        #expect(saved["url"]?.stringValue == "https://example.com/pricing")
        #expect(saved["title"]?.stringValue == "Pricing")
        #expect(saved["selector"]?.stringValue == "main > h1")
        #expect(saved["quote"]?.stringValue == "Simple pricing")
        #expect(saved["message"]?.stringValue == "Make this bigger")
        // The host's threaded prompt names the page and quotes the card's text.
        #expect(saved["place"]?.stringValue == "https://example.com/pricing")
        #expect(saved["submissionText"]?.stringValue == Self.comment.prompt)
        // Then sent threaded to the chat's acpmux session, once, under the fresh opid.
        #expect(host.sends.count == 1)
        #expect(host.sends.first?.session == "acp-7")
        #expect(host.sends.first?.ids == ["c1"])
        #expect(host.sends.first?.text == nil)
        #expect(host.sends.first?.key == "op-1")
        #expect(host.keys == ["op-1-save"])
        // The comment stays on the host: its thread now waits for the agent.
        #expect(host.comments[Self.root]?.count == 1)
        #expect(thread == BrowserCommentThread(commentID: "c1", state: .sent))
        #expect(threads.threads["card-1"] == thread)
        #expect(changes.map(\.1?.state) == [.sending, .sent])

        // Still unanswered: a list changes nothing.
        await threads.refresh()
        #expect(threads.threads["card-1"]?.state == .sent)
        #expect(threads.waiting)

        // The agent answers: the next list shows its reply in the same place.
        host.answer("c1", root: Self.root, reply: "Done: the heading is 48 pt now.")
        await threads.refresh()
        #expect(threads.threads["card-1"] == BrowserCommentThread(commentID: "c1", state: .answered,
                                                                    reply: "Done: the heading is 48 pt now."))
        #expect(changes.last?.0 == "card-1")
        #expect(changes.last?.1?.reply == "Done: the heading is 48 pt now.")
        #expect(!threads.waiting)
        // Nothing waits any more, so a refresh lists nothing.
        let lists = host.lists
        await threads.refresh()
        #expect(host.lists == lists)

        // Resolve deletes the comment and the thread goes.
        try await threads.resolve("card-1")
        #expect(host.comments[Self.root]?.isEmpty == true)
        #expect(threads.threads["card-1"] == nil)
        #expect(changes.last?.0 == "card-1")
        #expect(changes.last?.1 == nil)
    }

    @Test func sendNeedsAUserGesture() async {
        let host = ThreadingHost()
        let threads = BrowserCommentThreads(pollInterval: nil)
        await #expect(throws: BrowserCommentSendFailure.gestureRequired) {
            try await threads.send(Self.comment, key: "card-1", store: host, root: Self.root, acpSession: "acp-7",
                                   opid: "op-1", userGesture: false)
        }
        #expect(host.comments.isEmpty)
        #expect(host.sends.isEmpty)
        #expect(threads.threads.isEmpty)
    }

    @Test func aHostWithoutThreadsKeepsTheChipPath() async {
        let host = ThreadingHost()
        host.supportsCommentThreads = false
        let threads = BrowserCommentThreads(pollInterval: nil)
        await #expect(throws: BrowserCommentSendFailure.threadsUnavailable) {
            try await threads.send(Self.comment, key: "card-1", store: host, root: Self.root, acpSession: "acp-7",
                                   opid: "op-1", userGesture: true)
        }
        #expect(host.comments.isEmpty)
        #expect(threads.threads.isEmpty)
    }

    @Test func aSendTheHostRefusesDeletesTheSavedCommentAndShowsFailed() async {
        let host = ThreadingHost()
        host.refusesSend = true
        let threads = BrowserCommentThreads(pollInterval: nil)
        await #expect(throws: BrowserCommentSendFailure.self) {
            try await threads.send(Self.comment, key: "card-1", store: host, root: Self.root, acpSession: "acp-7",
                                   opid: "op-1", userGesture: true)
        }
        #expect(host.comments[Self.root]?.isEmpty == true)
        #expect(threads.threads["card-1"] == BrowserCommentThread(commentID: nil, state: .failed))
    }

    @Test func aCommentDeletedElsewhereTakesItsThreadAway() async throws {
        let host = ThreadingHost()
        let threads = BrowserCommentThreads(pollInterval: nil)
        try await threads.send(Self.comment, key: "card-1", store: host, root: Self.root, acpSession: "acp-7",
                               opid: "op-1", userGesture: true)
        host.comments[Self.root] = []
        await threads.refresh()
        #expect(threads.threads["card-1"] == nil)
    }
}
