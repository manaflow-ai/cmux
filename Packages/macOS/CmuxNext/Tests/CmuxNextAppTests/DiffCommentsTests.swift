import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// Diff line comments go back to the agent (hq #7563): the diff page's comments are kept by the
/// session host until sent, and Send to agent hands them all to the chat that opened the tab as one
/// prompt, then clears them. A tab names only its own repository, and a send needs a real click.
@MainActor
@Suite(.serialized)
struct DiffCommentsTests {
    /// The session host's `diff.comments.*`, in memory.
    final class StoringGit: DiffGitRunning, DiffCommentsStoring {
        var comments: [String: [JSONValue]] = [:]
        var keys: [String] = []

        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue { ["root": .string(repository)] }
        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue { ["files": []] }
        func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? { nil }

        func listComments(root: String) async throws(AgentPaneGitFailure) -> JSONValue {
            ["root": .string(root), "comments": .array(comments[root] ?? [])]
        }

        func saveComment(root: String, comment: JSONValue, key: String) async throws(AgentPaneGitFailure) -> JSONValue {
            keys.append(key)
            guard case .object(var record) = comment else { throw AgentPaneGitFailure.failed }
            record["id"] = .string("c\((comments[root]?.count ?? 0) + 1)")
            comments[root, default: []].append(.object(record))
            return ["comment": .object(record)]
        }

        func deleteComments(root: String, ids: [String], versions: [String: JSONValue], key: String) async throws(AgentPaneGitFailure) -> JSONValue {
            keys.append(key)
            let removed = (comments[root] ?? []).compactMap { comment -> String? in
                guard let id = comment["id"]?.stringValue, ids.contains(id) else { return nil }
                if let version = versions[id], comment["updatedAt"] != version { return nil }
                return id
            }
            comments[root]?.removeAll { removed.contains($0["id"]?.stringValue ?? "") }
            return ["deleted": .number(Double(removed.count)), "ids": .array(removed.map(JSONValue.string))]
        }
    }

    /// The chat that opened the tab: it takes prompts, or refuses them.
    final class Chat: @unchecked Sendable {
        var accepts = true
        var sent: [(String, String)] = []

        var tabChat: DiffTabChat {
            DiffTabChat(session: "chat-1", deliver: { [self] text, promptID in
                await MainActor.run {
                    sent.append((text, promptID))
                    return accepts
                }
            }, brief: { _ in nil })
        }
    }

    static let repository = "/Users/dev/uploader"

    private func provider(git: StoringGit, chat: Chat?) throws -> (DiffPageProvider, DiffSessionGrant, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-comments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let grant = try DiffSessionGrant.create(root: root, repository: Self.repository)
        let config: JSONValue = ["payload": ["repoRoot": .string(Self.repository)], "ops": []]
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: config) }, sidecar: nil, languages: nil, git: git)
        let tabChat = chat?.tabChat
        provider.chat = { tabChat }
        return (provider, grant, root)
    }

    private func comments(_ method: String, _ params: JSONValue) -> JSONValue {
        ["method": .string(method), "params": params]
    }

    @Test func commentsAreKeptBySessionHostAndSentToTheChatAsOnePrompt() async throws {
        let git = StoringGit(), host = Chat()
        let (provider, grant, root) = try provider(git: git, chat: host)
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let page = PageCallContext(page: "cmux.diff")

        let config = try await provider.call("cmux.diff.config", params: [:], context: page)
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.comments") == true)
        #expect(config["payload"]?["commentsSend"]?.boolValue == true)

        let comment: JSONValue = ["filePath": "src/upload.ts", "side": "additions", "startLine": 3, "endLine": 3,
                                  "lineText": "retry(3)", "message": "Use 5", "submissionText": "Review comment on src/upload.ts line 3"]
        let saved = try await provider.call("cmux.diff.comments", params: comments("comments.save", [
            "repoRoot": .string(Self.repository), "comment": comment,
        ]), context: page)
        #expect(saved["comment"]?["id"]?.stringValue == "c1")
        // A page closed and opened again lists it: the session host has it, not the page.
        let listed = try await provider.call("cmux.diff.comments", params: comments("comments.list", ["repoRoot": .string(Self.repository)]), context: page)
        #expect(listed["comments"]?.arrayValue?.count == 1)

        // A send needs a real click or key.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.comments", params: comments("comments.send", [
                "repoRoot": .string(Self.repository), "ids": ["c1"], "text": "Review comment on src/upload.ts line 3",
            ]), context: page)
        }
        #expect(host.sent.isEmpty)

        let clicked = PageCallContext(page: "cmux.diff", opid: "diff-comments-1", userGesture: true)
        // The chat refused: the comment stays.
        host.accepts = false
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.comments", params: comments("comments.send", [
                "repoRoot": .string(Self.repository), "ids": ["c1"], "text": "Review comment on src/upload.ts line 3",
            ]), context: clicked)
        }
        #expect(git.comments[Self.repository]?.count == 1)

        host.accepts = true
        _ = try await provider.call("cmux.diff.comments", params: comments("comments.send", [
            "repoRoot": .string(Self.repository), "ids": ["c1"], "text": "Review comment on src/upload.ts line 3",
        ]), context: clicked)
        #expect(host.sent.last?.0 == "Review comment on src/upload.ts line 3")
        #expect(host.sent.last?.1 == "diff-comments-1")
        #expect(git.comments[Self.repository]?.isEmpty == true)
        await provider.close()
    }

    @Test func aCommentEditedSinceTheSendStaysInTheStore() async throws {
        let git = StoringGit(), chat = Chat()
        let (provider, grant, root) = try provider(git: git, chat: chat)
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let page = PageCallContext(page: "cmux.diff")
        for message in ["Use 5", "Name it"] {
            _ = try await provider.call("cmux.diff.comments", params: comments("comments.save", [
                "repoRoot": .string(Self.repository),
                "comment": ["filePath": "a.ts", "message": .string(message), "updatedAt": "2026-11-07T00:00:00.000Z"],
            ]), context: page)
        }
        // c2 was edited after the page sent it: the version the page sent is older than the store's.
        let reply = try await provider.call("cmux.diff.comments", params: comments("comments.send", [
            "repoRoot": .string(Self.repository), "ids": ["c1", "c2"], "text": "review",
            "versions": ["c1": "2026-11-07T00:00:00.000Z", "c2": "2026-11-06T23:59:00.000Z"],
        ]), context: PageCallContext(page: "cmux.diff", opid: "diff-comments-2", userGesture: true))
        #expect(reply["cleared"]?.arrayValue?.compactMap(\.stringValue) == ["c1"])
        #expect(git.comments[Self.repository]?.compactMap { $0["id"]?.stringValue } == ["c2"])
        await provider.close()
    }

    @Test func aTabNamesOnlyItsOwnRepositoryAndWithoutAChatOffersNoSend() async throws {
        let git = StoringGit()
        let (provider, grant, root) = try provider(git: git, chat: nil)
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let page = PageCallContext(page: "cmux.diff")

        let config = try await provider.call("cmux.diff.config", params: [:], context: page)
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.comments") == true)
        #expect(config["payload"]?["commentsSend"] == nil)

        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.comments", params: comments("comments.list", ["repoRoot": "/etc"]), context: page)
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.comments", params: comments("comments.send", [
                "repoRoot": .string(Self.repository), "ids": ["c1"], "text": "x",
            ]), context: PageCallContext(page: "cmux.diff", userGesture: true))
        }
        await provider.close()
    }
}
