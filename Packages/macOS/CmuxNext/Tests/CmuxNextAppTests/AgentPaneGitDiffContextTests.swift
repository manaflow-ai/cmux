@testable import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemonService

/// Show more lines in the changes view (cx-ncc.85): the page asks for one file's patch with
/// enough unchanged lines to hold the whole file, `git.diff` or `git.checkpoint.diff` with
/// `paths` and `context_lines`. The App passes both to the session host as it reads them, and
/// refuses a path that leaves the repository or a count past the host's limit rather than drop it
/// (dropping either would be another read).
struct AgentPaneGitDiffContextTests {
    @Test func patchPageOffsetsRemainExactAndRequireTheirFirstRevision() throws {
        let revision = String(repeating: "a", count: 64)
        let params: [String: Any] = ["cwd": "/repo", "scope": "uncommitted", "include_patch": true,
                                   "paths": ["large.txt"], "patch_offset": "9007199254740993", "patch_revision": revision]
        let request = try #require(AgentPaneGitRequest(method: "git.diff", params: params))
        #expect(request.sessionHostParams["patch_offset"] == .string("9007199254740993"))
        #expect(request.sessionHostParams["patch_revision"] == .string(revision))
        var invalid = params
        invalid.removeValue(forKey: "patch_revision")
        #expect(AgentPaneGitRequest(method: "git.diff", params: invalid) == nil)
        invalid["patch_offset"] = "01"
        #expect(AgentPaneGitRequest(method: "git.diff", params: invalid) == nil)
        invalid["patch_offset"] = 0
        #expect(AgentPaneGitRequest(method: "git.diff", params: invalid) == nil)
    }

    @Test func aDiffForOneFileWithMoreContextReachesTheSessionHost() throws {
        let request = try #require(AgentPaneGitRequest(method: "git.diff", params: [
            "cwd": "/repo", "scope": "uncommitted", "include_patch": true,
            "paths": ["src/a.txt"], "context_lines": 100_000,
        ]))
        let params = request.sessionHostParams
        #expect(params["paths"] == .array([.string("src/a.txt")]))
        #expect(params["context_lines"] == .number(100_000))
        #expect(params["scope"] == .string("uncommitted"))
    }

    @Test func aCheckpointDiffForOneFileWithMoreContextReachesTheSessionHost() throws {
        let request = try #require(AgentPaneGitRequest(method: "git.checkpoint.diff", params: [
            "cwd": "/repo", "from": "c1", "include_patch": true, "paths": ["a.txt"], "context_lines": 500,
        ]))
        let params = request.sessionHostParams
        #expect(params["paths"] == .array([.string("a.txt")]))
        #expect(params["context_lines"] == .number(500))
    }

    @Test func aPathOutsideTheRepositoryOrTooMuchContextIsRefused() {
        let diff = { (extra: [String: Any]) in
            AgentPaneGitRequest(method: "git.diff", params: ["cwd": "/repo", "scope": "uncommitted"].merging(extra) { _, new in new })
        }
        #expect(diff(["paths": ["../secret"]]) == nil)
        #expect(diff(["paths": ["/etc/passwd"]]) == nil)
        #expect(diff(["paths": "a.txt"]) == nil)
        #expect(diff(["context_lines": 1_000_001]) == nil)
        #expect(diff(["context_lines": -1]) == nil)
        #expect(diff(["context_lines": true]) == nil)
        // Without either, the read is the one it always was.
        #expect(diff([:])?.sessionHostParams["paths"] == nil)
        #expect(diff([:])?.sessionHostParams["context_lines"] == nil)
    }
}
