import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

/// The diff tab's hunk sentences: `cmux.diff.summary` relays acpmux's `_acpmux/hunk_summary`
/// answer, `cmux.diff.summaryCheck` says whether a harness could answer (and why not), and a tab
/// with no summarizer lists neither op.
@MainActor
@Suite(.serialized)
struct DiffHunkSummariesTests {
    final class Git: DiffGitRunning {
        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue { ["root": .string(repository)] }
        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue { ["files": []] }
        func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? { nil }
    }

    /// What acpmux answers, and the hunks it was asked for.
    final class Sentences: @unchecked Sendable {
        var asked: [String] = []
        var refusal: AcpmuxRPCError?

        var summarizer: DiffHunkSummarizer {
            DiffHunkSummarizer(summarize: { [self] path, patch in
                try await MainActor.run {
                    asked.append("\(path):\(patch)")
                    if let refusal { throw refusal }
                    return Data(#"{"text":"Retries the upload.","key":"k","cached":false}"#.utf8)
                }
            }, check: { [self] in
                try await MainActor.run {
                    if let refusal { throw refusal }
                    return Data(#"{"ready":true,"harness":"claude"}"#.utf8)
                }
            })
        }
    }

    static let repository = "/Users/dev/uploader"

    private func provider(_ sentences: Sentences?) throws -> (DiffPageProvider, DiffSessionGrant, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-summaries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let grant = try DiffSessionGrant.create(root: root, repository: Self.repository)
        let config: JSONValue = ["payload": ["repoRoot": .string(Self.repository)], "ops": []]
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: config) }, sidecar: nil, languages: nil, git: Git())
        let summarizer = sentences?.summarizer
        provider.summarizer = { summarizer }
        return (provider, grant, root)
    }

    @Test func aTabRelaysAHunksSentence() async throws {
        let sentences = Sentences()
        let (provider, grant, root) = try provider(sentences)
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let page = PageCallContext(page: "cmux.diff")

        let config = try await provider.call("cmux.diff.config", params: [:], context: page)
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.summary") == true)
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.summaryCheck") == true)

        let check = try await provider.call("cmux.diff.summaryCheck", params: [:], context: page)
        #expect(check["ready"]?.boolValue == true)

        let answer = try await provider.call("cmux.diff.summary", params: ["path": "a.rs", "patch": "@@ -1 +1 @@\n-a\n+b"], context: page)
        #expect(answer["text"]?.stringValue == "Retries the upload.")
        #expect(sentences.asked == ["a.rs:@@ -1 +1 @@\n-a\n+b"])

        // No patch, or one past acpmux's limit, asks nothing.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.summary", params: ["path": "a.rs"], context: page)
        }
        let huge = String(repeating: "+x\n", count: 100_000)
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.summary", params: ["path": "a.rs", "patch": .string(huge)], context: page)
        }
        #expect(sentences.asked.count == 1)
    }

    @Test func aRefusalIsTheCheckReason() async throws {
        let sentences = Sentences()
        sentences.refusal = AcpmuxRPCError(name: "complete.not_installed", message: "claude is not installed")
        let (provider, grant, root) = try provider(sentences)
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let page = PageCallContext(page: "cmux.diff")

        let check = try await provider.call("cmux.diff.summaryCheck", params: [:], context: page)
        #expect(check["ready"]?.boolValue == false)
        #expect(check["reason"]?.stringValue == "complete.not_installed")
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.summary", params: ["path": "a.rs", "patch": "+b"], context: page)
        }
    }

    @Test func aTabWithNoSummarizerListsNoSummaryOp() async throws {
        let (provider, grant, root) = try provider(nil)
        defer { grant.remove(); try? FileManager.default.removeItem(at: root) }
        let page = PageCallContext(page: "cmux.diff")

        let config = try await provider.call("cmux.diff.config", params: [:], context: page)
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.summary") != true)
        let check = try await provider.call("cmux.diff.summaryCheck", params: [:], context: page)
        #expect(check["ready"]?.boolValue == false)
        #expect(check["reason"]?.stringValue == "cmux.diff.no_acpmux")
    }
}
