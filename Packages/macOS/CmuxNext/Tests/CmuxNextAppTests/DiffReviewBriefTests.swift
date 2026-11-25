import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// The diff tab's review brief: `cmux.diff.brief` relays acpmux's `_acpmux/review_brief` answer for
/// the chat that opened the tab, for the tab's own repository only; a tab no chat owns serves none.
@MainActor
@Suite(.serialized)
struct DiffReviewBriefTests {
    final class Git: DiffGitRunning {
        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue { ["root": .string(repository)] }
        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue { ["files": []] }
        func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? { nil }
    }

    /// What the chat's acpmux answers, and the roots it was asked for.
    final class Briefs: @unchecked Sendable {
        var answer: Data? = Data(#"{"sessionId":"chat-1","seq":17,"brief":{"goal":"Retry chunks","unsure":[]}}"#.utf8)
        var fails = false
        var roots: [String] = []

        var tabChat: DiffTabChat {
            DiffTabChat(session: "chat-1", deliver: { _, _ in true }, brief: { [self] root in
                try await MainActor.run {
                    roots.append(root)
                    if fails { throw URLError(.cannotConnectToHost) }
                    return answer
                }
            })
        }
    }

    static let repository = "/Users/dev/uploader"

    private func provider(briefs: Briefs?) throws -> (DiffPageProvider, DiffSessionGrant, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-brief-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let grant = try DiffSessionGrant.create(root: root, repository: Self.repository)
        let config: JSONValue = ["payload": ["repoRoot": .string(Self.repository)], "ops": []]
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: config) }, sidecar: nil, languages: nil, git: Git())
        let tabChat = briefs?.tabChat
        provider.chat = { tabChat }
        return (provider, grant, root)
    }

    @Test func aChatsTabServesItsBriefForItsOwnRepositoryOnly() async throws {
        let briefs = Briefs()
        let (provider, grant, root) = try provider(briefs: briefs)
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let page = PageCallContext(page: "cmux.diff")

        let config = try await provider.call("cmux.diff.config", params: [:], context: page)
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.brief") == true)
        #expect(config["payload"]?["reviewBrief"]?.boolValue == true)

        let answer = try await provider.call("cmux.diff.brief", params: ["repoRoot": .string(Self.repository)], context: page)
        #expect(answer["brief"]?["goal"]?.stringValue == "Retry chunks")
        #expect(briefs.roots == [Self.repository])

        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.brief", params: ["repoRoot": "/Users/dev/other"], context: page)
        }
        #expect(briefs.roots == [Self.repository])

        briefs.fails = true
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.brief", params: ["repoRoot": .string(Self.repository)], context: page)
        }
    }

    @Test func aTabNoChatOwnsServesNoBrief() async throws {
        let (provider, grant, root) = try provider(briefs: nil)
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let page = PageCallContext(page: "cmux.diff")

        let config = try await provider.call("cmux.diff.config", params: [:], context: page)
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.brief") != true)
        #expect(config["payload"]?["reviewBrief"] == nil)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.brief", params: ["repoRoot": .string(Self.repository)], context: page)
        }
    }
}
