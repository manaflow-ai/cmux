import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDiff

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
        /// The one file's patch the repository's diff shows now.
        var patch = "@@ -1 +1 @@\n-// retry 3 times\n+// retry 9 times\n"

        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue {
            ["head": "0123456789abcdef0123456789abcdef01234567", "root": .string(repository)]
        }

        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue {
            var file: [String: JSONValue] = ["path": "install.sh", "additions": 1, "deletions": 1]
            if includePatch { file["patch"] = .string(patch) }
            return ["files": [.object(file)], "scope": .string(scope.rawValue)]
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

    /// Remote Changes uses the daemon's patch and never starts a local sidecar
    /// or reads the same path on this Mac.
    final class RemoteGit: DiffGitRunning {
        let isRemote = true
        var calls: [(AgentPaneGitScope, AgentPaneGitDiffOptions?)] = []
        var partialContext = false
        var pagedPatch: Data?
        var initialStatus = "modified"
        var beforePage: (() async -> Void)?
        var holdNextOverview = false
        var branchChangeStarted: AsyncStream<Void>.Continuation?
        var branchChangeGate: AsyncStream<Void>?

        func status(_ repository: String) async throws(AgentPaneGitFailure) -> JSONValue { ["root": .string(repository)] }

        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool) async throws(AgentPaneGitFailure) -> JSONValue {
            calls.append((scope, nil))
            if holdNextOverview {
                holdNextOverview = false
                branchChangeStarted?.yield()
                branchChangeStarted?.finish()
                if let branchChangeGate {
                    for await _ in branchChangeGate { break }
                }
            }
            return ["files": [["path": "remote.txt", "status": "modified", "patch": "@@ -1 +1 @@\n-old\n+new\n"]]]
        }

        func diff(_ repository: String, scope: AgentPaneGitScope, includePatch: Bool,
                  options: AgentPaneGitDiffOptions) async throws(AgentPaneGitFailure) -> JSONValue {
            calls.append((scope, options))
            if let offset = options.patchOffset, let bytes = pagedPatch {
                if let beforePage {
                    self.beforePage = nil
                    await beforePage()
                }
                let start = Int(offset), end = min(start + 256 * 1024, bytes.count)
                let revision = String(repeating: "a", count: 64)
                #expect(options.patchRevision == (offset == 0 ? nil : revision))
                return ["patch_page": ["offset": .string(String(start)), "next_offset": .string(String(end)),
                    "total_bytes": .string(String(bytes.count)), "revision": .string(revision),
                    "data_base64": .string(bytes.subdata(in: start..<end).base64EncodedString()), "complete": .bool(end == bytes.count)]]
            }
            if pagedPatch != nil {
                return ["files": [["path": "remote.txt", "status": .string(initialStatus), "patch_truncated": true]]]
            }
            // 100,000 unchanged blank lines fit under the daemon's 256 KiB per-file cap. The
            // hunk is internally valid, but its context reaches the request bound and therefore
            // cannot prove that the remote file has no final line beyond the emitted patch.
            let patch = partialContext
                ? "@@ -1,100001 +1,100001 @@\n-old\n+new\n" + String(repeating: " \n", count: 100_000)
                : "@@ -1 +1 @@\n-old\n+new\n"
            return ["files": [["path": "remote.txt", "status": "modified", "patch": .string(patch)]]]
        }

        func write(_ request: AgentPaneGitWrite, in repository: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
        func stage(_ request: AgentPaneGitStage, in repository: String) async -> String? { "must not touch local files" }
        func checkpointDiff(_ repository: String, from: String, to: String) async throws(AgentPaneGitFailure) -> JSONValue { [:] }
    }

    @Test func aTruncatedRemoteFileLoadsEveryPatchPageBeforeRenderingContents() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-remote-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: "/remote/worktree")
        defer { grant.remove() }
        let remote = RemoteGit()
        let expected = String(repeating: "café changed payload\n", count: 80_000)
        remote.pagedPatch = Data(("diff --git a/remote.txt b/remote.txt\n--- a/remote.txt\n+++ b/remote.txt\n@@ -1 +1,80000 @@\n-old\n"
            + String(repeating: "+café changed payload\n", count: 80_000)).utf8)
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil, git: remote)
        let opened = try await provider.call("cmux.diff.sessionOpen", params: ["source": ["kind": "unstaged"]], context: PageCallContext(page: "cmux.diff"))
        let session = try #require(opened["value"]?["sessionId"]?.stringValue)
        let contents = try await provider.call("cmux.diff.fileContents", params: ["sessionId": .string(session), "path": "remote.txt"], context: PageCallContext(page: "cmux.diff"))
        #expect(contents["value"]?["old"]?["contents"]?.stringValue == "old\n")
        #expect(contents["value"]?["new"]?["contents"]?.stringValue == expected)
        #expect(remote.calls.compactMap { $0.1?.patchOffset }.count > 1)
        await provider.close()
    }

    @Test func capturedSideHeadersOverrideAStaleOverviewStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-remote-side-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: "/remote/worktree")
        defer { grant.remove() }
        let remote = RemoteGit()
        remote.pagedPatch = Data("diff --git a/remote.txt b/remote.txt\n--- a/remote.txt\n+++ b/remote.txt\n@@ -1 +1 @@\n-old\n+recreated\n".utf8)
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil, git: remote)
        let context = PageCallContext(page: "cmux.diff")
        let opened = try await provider.call("cmux.diff.sessionOpen", params: ["source": ["kind": "unstaged"]], context: context)
        let session = try #require(opened["value"]?["sessionId"]?.stringValue)
        for staleStatus in ["deleted", "added"] {
            remote.initialStatus = staleStatus
            let contents = try await provider.call("cmux.diff.fileContents", params: ["sessionId": .string(session), "path": "remote.txt"], context: context)
            #expect(contents["value"]?["old"]?["contents"]?.stringValue == "old\n")
            #expect(contents["value"]?["new"]?["contents"]?.stringValue == "recreated\n")
        }
        await provider.close()
    }

    @Test func changingBranchesRetiresAnInFlightFileReadEvenWhenTheSessionIDIsReused() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-remote-replaced-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: "/remote/worktree")
        defer { grant.remove() }
        let remote = RemoteGit()
        remote.pagedPatch = Data("@@ -1 +1 @@\n-old\n+new\n".utf8)
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil, git: remote)
        let context = PageCallContext(page: "cmux.diff")
        let opened = try await provider.call("cmux.diff.sessionOpen", params: ["source": ["kind": "unstaged"]], context: context)
        let session = try #require(opened["value"]?["sessionId"]?.stringValue)
        var replaced = false
        remote.beforePage = {
            _ = try? await provider.call("cmux.diff.branchChange", params: ["sessionId": .string(session), "baseRef": "HEAD"], context: context)
            replaced = true
        }
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.diff.fileContents", params: ["sessionId": .string(session), "path": "remote.txt"], context: context)
        }
        #expect(replaced)
        await provider.close()
    }

    @Test func changingBranchesInvalidatesReadsBeforeTheReplacementDiffCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-remote-early-retire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: "/remote/worktree")
        defer { grant.remove() }
        let remote = RemoteGit()
        remote.pagedPatch = Data("@@ -1 +1 @@\n-old\n+new\n".utf8)
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil, git: remote)
        let context = PageCallContext(page: "cmux.diff")
        let opened = try await provider.call("cmux.diff.sessionOpen", params: ["source": ["kind": "unstaged"]], context: context)
        let session = try #require(opened["value"]?["sessionId"]?.stringValue)

        // Hold the replacement's overview request after branchChange has begun.
        let (startedEvents, started) = AsyncStream<Void>.makeStream()
        let (gateEvents, openGate) = AsyncStream<Void>.makeStream()
        remote.branchChangeStarted = started
        remote.branchChangeGate = gateEvents
        remote.holdNextOverview = true
        let branchTask = Task {
            try? await provider.call("cmux.diff.branchChange", params: ["sessionId": .string(session), "baseRef": "HEAD"], context: context)
        }
        var startedIterator = startedEvents.makeAsyncIterator()
        _ = await startedIterator.next()

        // The old implementation kept the session valid until the replacement
        // diff returned. A file read could therefore complete from the old
        // branch while this replacement was still waiting on its overview.
        let contents = try? await provider.call("cmux.diff.fileContents", params: ["sessionId": .string(session), "path": "remote.txt"], context: context)
        #expect(contents == nil)

        openGate.yield()
        openGate.finish()
        _ = await branchTask.value
        await provider.close()
    }

    @Test func remoteDiffUsesTheDaemonPatchAndBoundedFileRead() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: "/remote/worktree")
        defer { grant.remove() }
        let remote = RemoteGit()
        // sidecar is deliberately nil: a remote provider must materialize through DiffGitRunning.
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil,
                                        languages: nil, git: remote)
        let opened = try await provider.call("cmux.diff.sessionOpen", params: [
            "source": ["kind": "unstaged", "repoRoot": "/remote/worktree"],
        ], context: PageCallContext(page: "cmux.diff"))
        let session = try #require(opened["value"]?["sessionId"]?.stringValue)
        #expect(try String(contentsOf: grant.remotePatchURL, encoding: .utf8).contains("diff --git a/remote.txt b/remote.txt"))
        #expect(opened["value"]?["patch"]?["id"]?.stringValue?.contains(grant.token) == true)
        let contents = try await provider.call("cmux.diff.fileContents", params: [
            "sessionId": .string(session), "path": "remote.txt",
        ], context: PageCallContext(page: "cmux.diff"))
        #expect(contents["value"]?["old"]?["contents"]?.stringValue == "old\n")
        #expect(contents["value"]?["new"]?["contents"]?.stringValue == "new\n")
        #expect(remote.calls.contains { $0.1?.contextLines == 100_000 })

        remote.calls.removeAll()
        _ = try await provider.call("cmux.diff.sessionOpen", params: [
            "source": ["kind": "branch", "baseRef": "HEAD", "repoRoot": "/remote/worktree"],
        ], context: PageCallContext(page: "cmux.diff"))
        #expect(remote.calls.first?.0 == .uncommitted)

        remote.partialContext = true
        let partial = try await provider.call("cmux.diff.fileContents", params: [
            "sessionId": .string(session), "path": "remote.txt",
        ], context: PageCallContext(page: "cmux.diff"))
        #expect(partial["value"]?["tooLarge"]?.boolValue == true)
        await provider.close()
    }

    @Test func aDiffTabStagesAndCommitsInItsOwnRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: Self.repository)
        defer { grant.remove() }
        let git = RecordingGit()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil, git: git)
        let clicked = PageCallContext(page: "cmux.diff", userGesture: true)

        // The page learns the ops from its config, and reads without a gesture.
        let config = try await provider.call("cmux.diff.config", params: [:], context: PageCallContext(page: "cmux.diff"))
        #expect(config["ops"]?.arrayValue?.contains("cmux.diff.git.commit") == true)
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

    /// The viewer refreshes after an agent edits the files it shows (cx-9ce.34): the page asks for a
    /// fingerprint of its scope's diff, which changes with any edit, even one that keeps the counts
    /// (a reworded comment), and stays the same otherwise.
    @Test func aDiffTabsFingerprintFollowsEveryEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diff-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grant = try DiffSessionGrant.create(root: root, repository: Self.repository)
        defer { grant.remove() }
        let git = RecordingGit()
        let provider = DiffPageProvider(ready: Task { DiffTabReady(grant: grant, config: [:]) }, sidecar: nil, languages: nil, git: git)
        let page = PageCallContext(page: "cmux.diff")
        let fingerprint = { try await provider.call("cmux.diff.git.fingerprint", params: ["scope": "uncommitted"], context: page) }

        let first = try await fingerprint()["fingerprint"]?.stringValue
        #expect(first?.isEmpty == false)
        #expect(try await fingerprint()["fingerprint"]?.stringValue == first)
        git.patch = "@@ -1 +1 @@\n-// retry 3 times\n+// retry up to 9 times\n"
        #expect(try await fingerprint()["fingerprint"]?.stringValue != first)
        await provider.close()
    }
}
