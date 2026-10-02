import Foundation
import Testing
@testable import CmuxNextAgentPane

private struct GitReadFailed: Error {}

/// `git.diff` and `git.status` from the changes view: which params the host
/// accepts, and how the model answers the page with the session host's reply.
@MainActor
@Suite struct AgentPaneGitTests {
    private static func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params] as [String: Any])
    }

    @Test func aDiffCarriesTheFolderTheScopeAndWhetherToIncludePatches() {
        #expect(Self.request("git.diff", ["cwd": "/repo", "scope": "staged", "include_patch": true])
            == .git(.diff(cwd: "/repo", scope: .staged, includePatch: true)))
        #expect(Self.request("git.diff", ["cwd": "/repo/sub", "scope": "branch"])
            == .git(.diff(cwd: "/repo/sub", scope: .branch, includePatch: false)))
        for scope in ["uncommitted", "unstaged", "staged", "committed", "branch"] {
            #expect(Self.request("git.diff", ["cwd": "/repo", "scope": scope]) != .unsupported("git.diff"))
        }
        #expect(Self.request("git.status", ["cwd": "/repo"]) == .git(.status(cwd: "/repo")))
    }

    /// The folder must be absolute: the session host resolves a relative or
    /// `~` path against its own directory, not the chat's.
    @Test func aMissingOrRelativeFolderOrAnUnknownScopeIsRefused() {
        #expect(Self.request("git.diff", ["scope": "staged"]) == .unsupported("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "", "scope": "staged"]) == .unsupported("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "repo", "scope": "staged"]) == .unsupported("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "~/code/cmux", "scope": "staged"]) == .unsupported("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "/repo\u{0}", "scope": "staged"]) == .unsupported("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "/repo"]) == .unsupported("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "/repo", "scope": "lastTurn"]) == .unsupported("git.diff"))
        #expect(Self.request("git.diff", ["cwd": 7, "scope": "staged"]) == .unsupported("git.diff"))
        #expect(Self.request("git.status", [:]) == .unsupported("git.status"))
        #expect(Self.request("git.status", ["cwd": "relative"]) == .unsupported("git.status"))
    }

    /// The session host's operation and params: the folder as `path`.
    @Test func theRequestNamesTheSessionHostOperation() {
        let diff = AgentPaneGitRequest.diff(cwd: "/repo", scope: .committed, includePatch: true)
        #expect(diff.operation == "git.diff")
        #expect(diff.cwd == "/repo")
        let status = AgentPaneGitRequest.status(cwd: "/repo")
        #expect(status.operation == "git.status")
        #expect(status.cwd == "/repo")
    }

    @Test func theModelRepliesWithTheSessionHostsResult() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var asked: [AgentPaneGitRequest] = []
        model.onGit = { request in
            asked.append(request)
            return Data(#"{"root":"/repo","files":[{"path":"a.ts","status":"modified","additions":1,"deletions":0}]}"#.utf8)
        }
        let request = AgentPaneGitRequest.diff(cwd: "/repo", scope: .staged, includePatch: true)
        let reply = await model.respond(to: .git(request))
        #expect(reply["ok"] as? Bool == true)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["root"] as? String == "/repo")
        let files = try #require(value["files"] as? [[String: Any]])
        #expect(files.first?["path"] as? String == "a.ts")
        #expect(asked == [request])
    }

    /// A failed read, or no session host wired, is a localized failure the
    /// changes view shows as its error state.
    @Test func aFailedReadOrNoHostIsALocalizedFailure() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var reply = await model.respond(to: .git(.status(cwd: "/repo")))
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "git_failed")
        model.onGit = { _ in throw GitReadFailed() }
        reply = await model.respond(to: .git(.status(cwd: "/repo")))
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "git_failed")
        #expect(error["userMessage"] as? String == AgentPaneModel.gitFailedMessage)
        // A reply that is not JSON fails the same way.
        model.onGit = { _ in Data("not json".utf8) }
        reply = await model.respond(to: .git(.status(cwd: "/repo")))
        #expect(reply["ok"] as? Bool == false)
    }
}
