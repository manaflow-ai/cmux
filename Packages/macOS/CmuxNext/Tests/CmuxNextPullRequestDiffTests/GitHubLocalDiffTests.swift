import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextPullRequestDiff

/// A pull request's diff from commits already on this Mac: read from a checkout of its repository
/// before GitHub, only for an open pull request whose commits are known, and never as a partial
/// diff.
@MainActor
@Suite
struct GitHubLocalDiffTests {
    private static let pull = URL(string: "https://github.com/manaflow-ai/cmux/pull/36002")!
    private static let base = String(repeating: "a", count: 40), head = String(repeating: "b", count: 40)
    nonisolated private static let ghPatch = "diff --git a/gh b/gh\n--- a/gh\n+++ b/gh\n@@ -1 +1 @@\n-a\n+b\n"

    private final class Calls: @unchecked Sendable { // crash-allow: test log touched only on the main actor
        var local: [[String: CmuxNextDaemon.JSONValue]] = []
        var gh = 0
    }

    private static func reply(_ files: [[String: Any]], omitted: Int = 0) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["files": files, "files_omitted": omitted])) ?? Data()
    }

    /// A cache with no gh that holds the pull request in `state` with both commits, and `folder` as a checkout of its repository.
    private static func cache(state: String = "OPEN", folder: String? = "/work/cmux") throws -> AgentReplyPullRequests {
        let cache = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: "/nonexistent/gh", environment: [:]))
        let view = #"{"url": "\#(pull.absoluteString)", "number": 36002, "state": "\#(state)", "updatedAt": "2026-11-05T10:00:00Z", "baseRefOid": "\#(base)", "headRefOid": "\#(head)"}"#
        cache.seed(try #require(AgentPanePullRequest(ghView: Data(view.utf8))), for: pull)
        if let folder { cache.noteFolder(folder, of: "Manaflow-AI/cmux") }
        return cache
    }

    /// View diff on the pull request: the diff it opened (or its web page's address).
    private static func open(_ cache: AgentReplyPullRequests, _ calls: Calls, local answer: Data?) async throws -> String {
        let link = try #require(GitHubLink(URL(string: pull.absoluteString + "/files")!))
        let diff = PullRequestDiff(local: GitHubLocalDiff(cache: cache) { params in
            calls.local.append(params)
            return answer
        }, read: { _ in
            await MainActor.run { calls.gh += 1 }
            return ghPatch
        })
        return await withCheckedContinuation { done in
            diff.open(link, openDiff: { done.resume(returning: $0) }, openWeb: { done.resume(returning: $0.absoluteString) })
        }
    }

    @Test func aReplyBecomesTheWholeUnifiedDiff() async throws {
        let data = Self.reply([
            ["path": "a.txt", "status": "modified", "additions": 1, "deletions": 1, "patch": "@@ -1 +1 @@\n-one\n+two\n"],
            ["path": "new.txt", "status": "added", "additions": 1, "deletions": 0, "patch": "@@ -0,0 +1 @@\n+new"],
            ["path": "old.txt", "status": "deleted", "additions": 0, "deletions": 1, "patch": "@@ -1 +0,0 @@\n-old\n"],
            ["path": "moved.txt", "previous_path": "was.txt", "status": "renamed", "additions": 0, "deletions": 0],
            ["path": "logo.png", "status": "added", "additions": 0, "deletions": 0, "binary": true],
        ])
        let text = try #require(await GitHubLocalDiff.unified(data))
        #expect(text == """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -one
            +two
            diff --git a/new.txt b/new.txt
            new file mode 100644
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1 @@
            +new
            diff --git a/old.txt b/old.txt
            deleted file mode 100644
            --- a/old.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -old
            diff --git a/was.txt b/moved.txt
            rename from was.txt
            rename to moved.txt
            diff --git a/logo.png b/logo.png
            new file mode 100644
            Binary files /dev/null and b/logo.png differ

            """)
    }

    @Test func aReplyThatLeftSomethingOutIsNoDiff() async {
        let cut: [String: Any] = ["path": "a.txt", "status": "modified", "additions": 1, "deletions": 0, "patch": "@@ -1 +1 @@\n+a\n",
                                  "patch_truncated": true]
        let missing: [String: Any] = ["path": "a.txt", "status": "modified", "additions": 3, "deletions": 0]
        let whole: [String: Any] = ["path": "a.txt", "status": "modified", "additions": 1, "deletions": 0, "patch": "@@ -1 +1 @@\n+a\n"]
        #expect(await GitHubLocalDiff.unified(Self.reply([cut])) == nil)
        #expect(await GitHubLocalDiff.unified(Self.reply([missing])) == nil)
        #expect(await GitHubLocalDiff.unified(Self.reply([whole], omitted: 1)) == nil)
        #expect(await GitHubLocalDiff.unified(Self.reply([])) == nil)
        #expect(await GitHubLocalDiff.unified(Data("not json".utf8)) == nil)
    }

    @Test func whatARebuiltHeaderCannotSayAsGitDoesIsNoDiff() async {
        let line = "@@ -1 +1 @@\n-a\n+b\n"
        for path in ["a\nb.txt", "say \"hi\".txt", "back\\slash.txt", "caf\u{e9}.txt", "tab\there.txt"] {
            let file: [String: Any] = ["path": path, "status": "modified", "additions": 1, "deletions": 1, "patch": line]
            #expect(await GitHubLocalDiff.unified(Self.reply([file])) == nil, "\(path)")
        }
        let renamedFrom: [String: Any] = ["path": "plain.txt", "previous_path": "caf\u{e9}.txt", "status": "renamed",
                                          "additions": 0, "deletions": 0]
        #expect(await GitHubLocalDiff.unified(Self.reply([renamedFrom])) == nil)
        // A mode-only change: modified with no lines and no patch.
        let modeOnly: [String: Any] = ["path": "run.sh", "status": "modified", "additions": 0, "deletions": 0]
        #expect(await GitHubLocalDiff.unified(Self.reply([modeOnly])) == nil)
        // An empty new file and a plain path still read.
        let empty: [String: Any] = ["path": "dir/with space.txt", "status": "added", "additions": 0, "deletions": 0]
        #expect(await GitHubLocalDiff.unified(Self.reply([empty])) == "diff --git a/dir/with space.txt b/dir/with space.txt\nnew file mode 100644\n")
    }

    @Test func anOpenPullRequestsDiffIsReadFromItsCommitsHereBeforeGitHub() async throws {
        let calls = Calls(), cache = try Self.cache()
        let local = Self.reply([["path": "a.txt", "status": "modified", "additions": 1, "deletions": 1, "patch": "@@ -1 +1 @@\n-a\n+b\n"]])
        let opened = try await Self.open(cache, calls, local: local)
        #expect(calls.gh == 0)
        #expect(calls.local.count == 1)
        let params = try #require(calls.local.first)
        #expect(params["path"] == .string("/work/cmux"))
        #expect(params["scope"] == .string("commits"))
        #expect(params["base"] == .string(Self.base))
        #expect(params["head"] == .string(Self.head))
        #expect(opened.hasPrefix("diff --git a/a.txt b/a.txt\n"))
    }

    @Test func aFolderWithoutTheCommitsFallsBackToGitHub() async throws {
        let calls = Calls(), cache = try Self.cache()
        let opened = try await Self.open(cache, calls, local: nil)
        #expect(calls.local.count == 1)
        #expect(calls.gh == 1)
        #expect(opened == Self.ghPatch)
    }

    @Test func aMergedPullRequestOrNoCheckoutIsReadFromGitHubOnly() async throws {
        for cache in [try Self.cache(state: "MERGED"), try Self.cache(folder: nil)] {
            let calls = Calls()
            _ = try await Self.open(cache, calls, local: Self.reply([]))
            #expect(calls.local.isEmpty)
            #expect(calls.gh == 1)
        }
    }

    @Test func foldersAreKeptPerRepositoryMostRecentFirst() {
        let cache = AgentReplyPullRequests(reader: AgentChatPullRequestReader(gh: "/nonexistent/gh", environment: [:]))
        cache.noteFolder("/a", of: "manaflow-ai/cmux")
        cache.noteFolder("/b", of: "manaflow-ai/cmux")
        cache.noteFolder("/a", of: "Manaflow-AI/CMUX")
        cache.noteFolder("relative", of: "manaflow-ai/cmux")
        #expect(cache.folders(of: "manaflow-ai/cmux") == ["/a", "/b"])
        #expect(cache.folders(of: "manaflow-ai/other").isEmpty)
    }
}
