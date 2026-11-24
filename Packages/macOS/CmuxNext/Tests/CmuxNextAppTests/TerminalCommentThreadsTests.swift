import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// Comment… on a terminal selection (`terminal.sendSelectionToChat`, comment-threads-v1): the
/// comment is saved on the session host as a terminal comment, sent to the workspace's chat with
/// `keep: true` so it stays as a thread, and the agent's reply shows in that thread on a later list.
/// Resolve deletes it.
@MainActor
@Suite(.serialized)
struct TerminalCommentThreadsTests {
    /// The session host's `diff.comments.*` with threads (`keep: true`), in memory.
    final class ThreadingHost: DiffCommentsStoring {
        var comments: [String: [JSONValue]] = [:]
        var keys: [String] = []
        /// Each keep send: its acpmux session, ids, text and key.
        var sends: [(session: String, ids: [String], text: String, key: String)] = []
        /// Each plain (clearing) send's key; a thread send must not use it.
        var clearingSends: [String] = []

        var keepsThreads: Bool { true }

        func listComments(root: String) async throws(AgentPaneGitFailure) -> JSONValue {
            ["root": .string(root), "comments": .array(comments[root] ?? [])]
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

        func sendComments(root: String, acpSession: String, ids: [String], versions: [String: JSONValue],
                          text: String, key: String) async throws(AgentPaneGitFailure) -> JSONValue {
            clearingSends.append(key)
            return ["sent": .number(Double(ids.count))]
        }

        func sendCommentThreads(root: String, acpSession: String, ids: [String], versions: [String: JSONValue],
                                text: String, key: String) async throws(AgentPaneGitFailure) -> JSONValue {
            sends.append((acpSession, ids, text, key))
            setThread(root: root, ids: ids, ["promptId": .string(key), "acpSession": .string(acpSession), "state": "sent"])
            return ["sent": .number(Double(ids.count)), "threaded": .array(ids.map(JSONValue.string))]
        }

        /// The agent's turn ended: the host fills the thread's reply.
        func answer(root: String, id: String, reply: String) {
            setThread(root: root, ids: [id], ["state": "answered", "reply": ["text": .string(reply), "at": .number(2)]])
        }

        private func setThread(root: String, ids: [String], _ fields: [String: JSONValue]) {
            comments[root] = (comments[root] ?? []).map { comment in
                guard case .object(var record) = comment, ids.contains(record["id"]?.stringValue ?? "") else { return comment }
                var thread: [String: JSONValue] = record["thread"]?.objectValue ?? [:]
                thread.merge(fields) { _, new in new }
                record["thread"] = .object(thread)
                return .object(record)
            }
        }
    }

    static let root = "/Users/me/project"
    static let terminal = CommentedTerminal(id: "tab-7", title: "zsh", cwd: "/Users/me/project")

    @Test func commentSavesAsTerminalSendsWithKeepAndShowsTheReply() async throws {
        let host = ThreadingHost()
        let model = CommentThreadsModel(root: Self.root, store: host, interval: .seconds(60))

        let thread = try await model.comment(on: Self.terminal, quote: "error: cannot find 'x' in scope\n",
                                             message: "why does this fail?", acpSession: "acp-1", key: "op-1")

        // Saved as a terminal comment on the terminal, under its own idempotency key.
        let saved = try #require(host.comments[Self.root]?.first)
        #expect(saved["surface"]?.stringValue == "terminal")
        #expect(saved["terminal"]?["id"]?.stringValue == "tab-7")
        #expect(saved["terminal"]?["title"]?.stringValue == "zsh")
        #expect(saved["terminal"]?["cwd"]?.stringValue == "/Users/me/project")
        #expect(saved["quote"]?.stringValue == "error: cannot find 'x' in scope\n")
        #expect(saved["message"]?.stringValue == "why does this fail?")
        #expect(host.keys == ["op-1-save"])

        // Sent with keep (a thread, not a clearing send) to the chat's session, under the opid.
        #expect(host.clearingSends.isEmpty)
        let send = try #require(host.sends.first)
        #expect(host.sends.count == 1)
        #expect(send.session == "acp-1")
        #expect(send.ids == [thread.id])
        #expect(send.key == "op-1")
        #expect(send.text.hasPrefix("> **Terminal · zsh (`/Users/me/project`)**\n> error: cannot find 'x' in scope"))
        #expect(send.text.hasSuffix("\n\nwhy does this fail?"))

        // The comment stays as a "sent" thread and polling runs while it waits.
        #expect(thread.state == .sent)
        #expect(model.threads(onTerminal: "tab-7").map(\.id) == [thread.id])
        #expect(model.threads(onTerminal: "tab-8").isEmpty)
        #expect(model.isWaiting)
        #expect(model.isPolling)

        // The agent answers: the next list shows the reply in the same thread, and polling ends.
        host.answer(root: Self.root, id: thread.id, reply: "`x` is declared after its use.")
        await model.refresh()
        let answered = try #require(model.threads(onTerminal: "tab-7").first)
        #expect(answered.state == .answered)
        #expect(answered.reply == "`x` is declared after its use.")
        #expect(answered.quote == "error: cannot find 'x' in scope\n")
        #expect(answered.message == "why does this fail?")
        #expect(!model.isWaiting)
        model.stopPolling()
        #expect(!model.isPolling)

        // Resolve deletes it on the host.
        await model.resolve(thread.id)
        #expect(model.threads.isEmpty)
        #expect(host.comments[Self.root]?.isEmpty == true)
        #expect(model.failure == nil)
    }

    @Test func aFailedTurnShowsAsFailed() async throws {
        let record: JSONValue = ["id": "c1", "surface": "terminal", "terminal": ["id": "tab-1"], "quote": "ls",
                                 "message": "hm", "thread": ["state": "failed"]]
        let thread = try #require(CommentThread(record))
        #expect(thread.state == .failed)
        #expect(thread.reply == nil)
        #expect(thread.terminalID == "tab-1")
    }

    @Test func aSendTheHostRefusesDeletesTheSavedCommentAndReportsIt() async throws {
        final class RefusingHost: DiffCommentsStoring {
            var saved: [JSONValue] = []
            var deleted: [String] = []
            func listComments(root: String) async throws(AgentPaneGitFailure) -> JSONValue { ["comments": .array(saved)] }
            func saveComment(root: String, comment: JSONValue, key: String) async throws(AgentPaneGitFailure) -> JSONValue {
                guard case .object(var record) = comment else { throw AgentPaneGitFailure.failed }
                record["id"] = "c1"
                saved.append(.object(record))
                return ["comment": .object(record)]
            }
            func deleteComments(root: String, ids: [String], versions: [String: JSONValue], key: String) async throws(AgentPaneGitFailure) -> JSONValue {
                deleted += ids
                return [:]
            }
            func sendComments(root: String, acpSession: String, ids: [String], versions: [String: JSONValue],
                              text: String, key: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
            // No sendCommentThreads: the protocol's default refuses, as a host without comment-threads-v1.
        }
        let host = RefusingHost()
        let model = CommentThreadsModel(root: Self.root, store: host, interval: .seconds(60))
        await #expect(throws: AgentPaneGitFailure.self) {
            try await model.comment(on: Self.terminal, quote: "ls", message: "?", acpSession: "acp-1", key: "op-2")
        }
        #expect(model.failure != nil)
        #expect(model.threads.isEmpty)
        #expect(host.deleted == ["c1"])
        #expect(!model.isPolling)
    }
}
