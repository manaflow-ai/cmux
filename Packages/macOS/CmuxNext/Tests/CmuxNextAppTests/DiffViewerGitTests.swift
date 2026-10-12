import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// The diff viewer stages, commits and pushes (cx-ueuc8, dogfood run hq #1893): the chat header's
/// ± opens it, and it had no Stage, Commit or Push, so the chat's changes workflow was out of reach
/// from there. Its page now calls `cmux.diff.git.*`, which run the changes view's git in the tab's
/// own repository: a folder the page names is ignored, and every write needs a real click or key.
@MainActor
@Suite(.serialized)
struct DiffViewerGitTests {
    final class RecordingGit: DiffGitRunning {
        var writes: [(AgentPaneGitWrite, String)] = []
        var stages: [(AgentPaneGitStage, String)] = []

        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue {
            ["head": "0123456789abcdef0123456789abcdef01234567", "root": .string(repository)]
        }

        func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue {
            writes.append((request, repository))
            return ["committed": true]
        }

        func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? {
            stages.append((request, repository))
            return nil
        }
    }

    static let repository = "/Users/dev/uploader"

    @Test func aDiffTabStagesAndCommitsInItsOwnRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: Self.repository)
        defer { grant.remove() }
        let git = RecordingGit()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil, git: git)
        let clicked = PageCallContext(page: "cmux.diff", userGesture: true)

        let status = try await provider.call("cmux.diff.git.status", params: ["path": "/etc"], context: PageCallContext(page: "cmux.diff"))
        #expect(status["root"]?.stringValue == Self.repository)

        _ = try await provider.call("cmux.diff.git.stage", params: ["paths": ["src/upload.ts"], "cwd": "/etc"], context: clicked)
        #expect(git.stages.map(\.0.cwd) == [Self.repository])
        #expect(git.stages.map(\.0.paths) == [["src/upload.ts"]])

        let key = UUID().uuidString
        _ = try await provider.call("cmux.diff.git.commit", params: [
            "message": "Retry the upload", "all": false, "idempotency_key": .string(key), "cwd": "/etc", "path": "/etc",
        ], context: clicked)
        #expect(git.writes.map(\.1) == [Self.repository])
        #expect(git.writes.first?.0 == .commit(sessionId: DiffPageProvider.gitSession, message: "Retry the upload", all: false,
                                               includeUntracked: false, expectedHead: nil, key: key))

        // A write without a real click or key in the page runs nothing.
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.git.push", params: ["idempotency_key": .string(UUID().uuidString)],
                                        context: PageCallContext(page: "cmux.diff"))
        }
        #expect(git.writes.count == 1)
        await provider.close()
    }
}
