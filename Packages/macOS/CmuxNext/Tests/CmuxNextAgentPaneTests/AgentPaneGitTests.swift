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
            #expect(Self.request("git.diff", ["cwd": "/repo", "scope": scope]) != .invalidGit("git.diff"))
        }
        #expect(Self.request("git.status", ["cwd": "/repo"]) == .git(.status(cwd: "/repo")))
    }

    /// The folder must be absolute: the session host resolves a relative or
    /// `~` path against its own directory, not the chat's.
    @Test func aMissingOrRelativeFolderOrAnUnknownScopeIsAnInvalidRequest() {
        #expect(Self.request("git.diff", ["scope": "staged"]) == .invalidGit("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "", "scope": "staged"]) == .invalidGit("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "repo", "scope": "staged"]) == .invalidGit("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "~/code/cmux", "scope": "staged"]) == .invalidGit("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "/repo\u{0}", "scope": "staged"]) == .invalidGit("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "/repo"]) == .invalidGit("git.diff"))
        #expect(Self.request("git.diff", ["cwd": "/repo", "scope": "lastTurn"]) == .invalidGit("git.diff"))
        #expect(Self.request("git.diff", ["cwd": 7, "scope": "staged"]) == .invalidGit("git.diff"))
        #expect(Self.request("git.status", [:]) == .invalidGit("git.status"))
        #expect(Self.request("git.status", ["cwd": "relative"]) == .invalidGit("git.status"))
    }

    /// `file.search` from @ mentions and the files palette: the folder as
    /// `path` or `cwd`, the query, and a limit from 1 to 200 (50 when absent).
    @Test func aFileSearchCarriesTheFolderTheQueryAndALimit() {
        #expect(Self.request("file.search", ["path": "/repo", "query": "app", "limit": 20])
            == .git(.filesSearch(cwd: "/repo", query: "app", limit: 20)))
        #expect(Self.request("file.search", ["cwd": "/repo/web", "query": ""])
            == .git(.filesSearch(cwd: "/repo/web", query: "", limit: 50)))
        #expect(Self.request("file.search", ["path": "/repo", "query": "x", "limit": 200]) != .invalidGit("file.search"))
        #expect(Self.request("file.search", ["query": "x"]) == .invalidGit("file.search"))
        #expect(Self.request("file.search", ["path": "repo", "query": "x"]) == .invalidGit("file.search"))
        #expect(Self.request("file.search", ["path": "/repo"]) == .invalidGit("file.search"))
        #expect(Self.request("file.search", ["path": "/repo", "query": String(repeating: "a", count: 257)])
            == .invalidGit("file.search"))
        for limit: Any in [0, 201, 2.5, "10", true] {
            #expect(Self.request("file.search", ["path": "/repo", "query": "x", "limit": limit])
                == .invalidGit("file.search"))
        }
        let search = AgentPaneGitRequest.filesSearch(cwd: "/repo", query: "app", limit: 20)
        #expect(search.operation == "git.files.search")
        #expect(search.cwd == "/repo")
    }

    /// `git.checkpoint.diff` for Last turn: the folder, the turn's checkpoints and
    /// whether to include patches; `to` is optional.
    @Test func aCheckpointDiffCarriesTheFolderAndTheTurnsCheckpoints() {
        #expect(Self.request("git.checkpoint.diff", ["cwd": "/repo", "from": "ckpt_a", "to": "ckpt_b", "include_patch": true])
            == .git(.checkpointDiff(cwd: "/repo", from: "ckpt_a", to: "ckpt_b", includePatch: true)))
        #expect(Self.request("git.checkpoint.diff", ["cwd": "/repo", "from": "ckpt_a"])
            == .git(.checkpointDiff(cwd: "/repo", from: "ckpt_a", to: nil, includePatch: false)))
        #expect(Self.request("git.checkpoint.diff", ["cwd": "/repo"]) == .invalidGit("git.checkpoint.diff"))
        #expect(Self.request("git.checkpoint.diff", ["cwd": "/repo", "from": ""]) == .invalidGit("git.checkpoint.diff"))
        #expect(Self.request("git.checkpoint.diff", ["cwd": "/repo", "from": "a b"]) == .invalidGit("git.checkpoint.diff"))
        #expect(Self.request("git.checkpoint.diff", ["cwd": "/repo", "from": "ckpt_a", "to": ""])
            == .invalidGit("git.checkpoint.diff"))
        #expect(Self.request("git.checkpoint.diff", ["from": "ckpt_a"]) == .invalidGit("git.checkpoint.diff"))
        #expect(AgentPaneGitRequest.checkpointDiff(cwd: "/repo", from: "a", to: nil, includePatch: false).operation
            == "git.checkpoint.diff")
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

    /// The `error` object of a failed reply, and its keys in order.
    private static func failure(_ reply: [String: Any]) throws -> (error: [String: Any], keys: [String]) {
        #expect(reply["ok"] as? Bool == false)
        let error = try #require(reply["error"] as? [String: Any])
        return (error, error.keys.sorted())
    }

    /// The session host answered with a resource error: its code, details
    /// and retryable flag reach the page verbatim, under the localized text.
    @Test func aSessionHostErrorRepliesWithItsCodeDetailsAndRetryable() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.onGit = { _ in
            throw AgentPaneGitFailure(
                code: "operation.failed", details: Data(#"{"stderr":"fatal: not a git repository","exit_code":128}"#.utf8),
                retryable: false, origin: .sessionHost)
        }
        let (error, keys) = try await Self.failure(model.respond(to: .git(.status(cwd: "/repo"))))
        #expect(keys == ["code", "details", "origin", "retryable", "userMessage"])
        #expect(error["code"] as? String == "operation.failed")
        #expect(error["origin"] as? String == "session_host")
        #expect(error["retryable"] as? Bool == false)
        #expect(error["userMessage"] as? String == AgentPaneModel.gitFailedMessage)
        let details = try #require(error["details"] as? [String: Any])
        #expect(details["stderr"] as? String == "fatal: not a git repository")
        #expect(details["exit_code"] as? Int == 128)
    }

    /// Details that are not an object (any JSON value) still reach the page,
    /// and a missing `retryable` is left out.
    @Test func sessionHostDetailsMayBeAnyJSONValue() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.onGit = { _ in
            throw AgentPaneGitFailure(code: "resource.not_found", details: Data(#""/repo""#.utf8), retryable: nil, origin: .sessionHost)
        }
        let (error, keys) = try await Self.failure(model.respond(to: .git(.status(cwd: "/repo"))))
        #expect(keys == ["code", "details", "origin", "userMessage"])
        #expect(error["details"] as? String == "/repo")
    }

    /// The request got no answer: a native code, no details or retryable.
    @Test func aNativeFailureRepliesWithItsCode() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let failures: [(AgentPaneGitFailure, String)] = [
            (.notConnected, "native.not_connected"),
            (.timedOut, "native.timed_out"),
            (.invalidRequest, "native.invalid_request"),
            (.failed, "native.failed")
        ]
        for (failure, code) in failures {
            #expect(failure.origin == .native)
            model.onGit = { _ in throw failure }
            let (error, keys) = try await Self.failure(model.respond(to: .git(.diff(cwd: "/repo", scope: .staged, includePatch: true))))
            #expect(keys == ["code", "origin", "userMessage"])
            #expect(error["code"] as? String == code)
            #expect(error["origin"] as? String == "native")
            #expect(error["userMessage"] as? String == AgentPaneModel.gitFailedMessage)
        }
    }

    /// No session host wired is never sent; any other error, or a result
    /// that is not JSON, is `native.failed`.
    @Test func noHostAnUnknownErrorOrAMalformedResultAreNativeFailures() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var (error, _) = try await Self.failure(model.respond(to: .git(.status(cwd: "/repo"))))
        #expect(error["code"] as? String == "native.not_connected")
        #expect(error["origin"] as? String == "native")
        model.onGit = { _ in throw GitReadFailed() }
        (error, _) = try await Self.failure(model.respond(to: .git(.status(cwd: "/repo"))))
        #expect(error["code"] as? String == "native.failed")
        #expect(error["origin"] as? String == "native")
        #expect(error["userMessage"] as? String == AgentPaneModel.gitFailedMessage)
        model.onGit = { _ in Data("not json".utf8) }
        (error, _) = try await Self.failure(model.respond(to: .git(.status(cwd: "/repo"))))
        #expect(error["code"] as? String == "native.failed")
    }

    /// Params the bridge refuses never reach the session host: the page
    /// gets `native.invalid_request` under the same localized text.
    @Test func anInvalidGitRequestRepliesInvalidRequest() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var asked = 0
        model.onGit = { _ in
            asked += 1
            return Data("{}".utf8)
        }
        for (method, params) in [("git.diff", ["cwd": "repo", "scope": "staged"]), ("git.status", [String: String]())] {
            let (error, keys) = try await Self.failure(model.respond(to: Self.request(method, params)))
            #expect(keys == ["code", "origin", "userMessage"])
            #expect(error["code"] as? String == "native.invalid_request")
            #expect(error["origin"] as? String == "native")
            #expect(error["userMessage"] as? String == AgentPaneModel.gitFailedMessage)
        }
        #expect(asked == 0)
    }

    /// The structured failure leaves nil fields out of the dictionary, so the
    /// page sees `undefined` rather than `null`.
    @Test func theFailureReplyLeavesOutNilFields() throws {
        let bare = AgentPaneReply.failure(code: "native.failed", message: "m", details: nil, retryable: nil, origin: "native")
        let (error, keys) = try Self.failure(bare)
        #expect(keys == ["code", "origin", "userMessage"])
        #expect(error["userMessage"] as? String == "m")
        let full = AgentPaneReply.failure(code: "operation.failed", message: "m", details: ["a": 1] as [String: Any], retryable: true, origin: "session_host")
        let (fullError, fullKeys) = try Self.failure(full)
        #expect(fullKeys == ["code", "details", "origin", "retryable", "userMessage"])
        #expect(fullError["retryable"] as? Bool == true)
        #expect((fullError["details"] as? [String: Any])?["a"] as? Int == 1)
    }
}
