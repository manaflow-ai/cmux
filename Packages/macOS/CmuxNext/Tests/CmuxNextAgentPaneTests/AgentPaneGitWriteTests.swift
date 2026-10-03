import Foundation
import Testing
@testable import CmuxNextAgentPane

/// `git.commit` and `git.push` from the changes view: which params the host
/// accepts, and how the model answers the page with the session host's reply.
@MainActor
@Suite struct AgentPaneGitWriteTests {
    private static let key = "6f1c2a3e-0b4d-4e5f-8a9b-0c1d2e3f4a5b"
    private static let head = "4be1c2e9a0f1b2c3d4e5f60718293a4b5c6d7e8f"

    private static func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params] as [String: Any])
    }

    @Test func aCommitCarriesTheFolderMessageScopeHeadAndKey() {
        #expect(Self.request("git.commit", ["cwd": "/repo", "message": "Fix upload", "idempotency_key": Self.key])
            == .gitWrite(.commit(cwd: "/repo", message: "Fix upload", all: false, includeUntracked: false, expectedHead: nil, key: Self.key)))
        let all = Self.request("git.commit", [
            "cwd": "/repo", "message": "Fix\n\nBody", "all": true, "include_untracked": true,
            "expected_head": Self.head, "idempotency_key": Self.key,
        ])
        #expect(all == .gitWrite(.commit(cwd: "/repo", message: "Fix\n\nBody", all: true, includeUntracked: true, expectedHead: Self.head, key: Self.key)))
        let write = AgentPaneGitWrite.commit(cwd: "/repo", message: "m", all: false, includeUntracked: false, expectedHead: nil, key: Self.key)
        #expect(write.operation == "git.commit")
        #expect(write.cwd == "/repo")
        #expect(write.key == Self.key)
    }

    @Test func aPushCarriesTheFolderHeadAndKey() {
        #expect(Self.request("git.push", ["cwd": "/repo", "expected_head": Self.head, "idempotency_key": Self.key])
            == .gitWrite(.push(cwd: "/repo", expectedHead: Self.head, key: Self.key)))
        #expect(Self.request("git.push", ["cwd": "/repo", "idempotency_key": Self.key])
            == .gitWrite(.push(cwd: "/repo", expectedHead: nil, key: Self.key)))
        #expect(AgentPaneGitWrite.push(cwd: "/repo", expectedHead: nil, key: Self.key).operation == "git.push")
    }

    /// Params the session host would refuse, or the page should never send,
    /// stop at the bridge: no folder or key, a relative folder, an empty or
    /// blank message, one over 64 KiB, untracked files without All, a head
    /// that is not a commit id, or a flag that is not a boolean.
    @Test func invalidParamsAreAnInvalidRequest() {
        let base: [String: Any] = ["cwd": "/repo", "message": "m", "idempotency_key": Self.key]
        let broken: [[String: Any]] = [
            base.filter { $0.key != "cwd" },
            base.merging(["cwd": "repo"]) { $1 },
            base.merging(["cwd": "/repo\u{0}"]) { $1 },
            base.filter { $0.key != "idempotency_key" },
            base.merging(["idempotency_key": ""]) { $1 },
            base.merging(["idempotency_key": "has space"]) { $1 },
            base.merging(["idempotency_key": String(repeating: "k", count: 129)]) { $1 },
            base.filter { $0.key != "message" },
            base.merging(["message": ""]) { $1 },
            base.merging(["message": " \n\t"]) { $1 },
            base.merging(["message": String(repeating: "a", count: AgentPaneGitWrite.maximumMessageBytes + 1)]) { $1 },
            base.merging(["include_untracked": true]) { $1 },
            base.merging(["all": "true"]) { $1 },
            base.merging(["all": 1]) { $1 },
            base.merging(["expected_head": "HEAD"]) { $1 },
            base.merging(["expected_head": "abc"]) { $1 },
            base.merging(["expected_head": 7]) { $1 },
        ]
        for params in broken {
            #expect(Self.request("git.commit", params) == .invalidGit("git.commit"))
        }
        #expect(Self.request("git.commit", base.merging(["message": String(repeating: "a", count: AgentPaneGitWrite.maximumMessageBytes)]) { $1 })
            != .invalidGit("git.commit"))
        #expect(Self.request("git.push", ["cwd": "/repo"]) == .invalidGit("git.push"))
        #expect(Self.request("git.push", ["cwd": "repo", "idempotency_key": Self.key]) == .invalidGit("git.push"))
        #expect(Self.request("git.push", ["cwd": "/repo", "idempotency_key": Self.key, "expected_head": "main"]) == .invalidGit("git.push"))
    }

    @Test func theModelRepliesWithTheMutationResult() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var asked: [AgentPaneGitWrite] = []
        model.onGitWrite = { request in
            asked.append(request)
            return Data(#"{"value":{"root":"/repo","commit":"abcd1234","summary":"Fix","files_changed":1,"additions":2,"deletions":0},"generation":"g","revision":3,"replayed":false}"#.utf8)
        }
        let write = AgentPaneGitWrite.push(cwd: "/repo", expectedHead: nil, key: Self.key)
        let reply = await model.respond(to: .gitWrite(write))
        #expect(reply["ok"] as? Bool == true)
        let value = try #require(reply["value"] as? [String: Any])
        #expect((value["value"] as? [String: Any])?["commit"] as? String == "abcd1234")
        #expect(value["replayed"] as? Bool == false)
        #expect(asked == [write])
    }

    /// A refusal keeps the session host's machine reason in `details`, under
    /// the write's own localized text; a lost reply is `native.timed_out`.
    @Test func aFailedWriteKeepsTheReasonUnderTheWriteText() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.onGitWrite = { _ in
            throw AgentPaneGitFailure(
                code: "operation.failed",
                details: Data(#"{"operation":"git.push","reason":"rejected_non_fast_forward","extra":{"message":"behind"}}"#.utf8),
                retryable: false, origin: .sessionHost)
        }
        var reply = await model.respond(to: .gitWrite(.push(cwd: "/repo", expectedHead: nil, key: Self.key)))
        var error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "operation.failed")
        #expect(error["origin"] as? String == "session_host")
        #expect(error["userMessage"] as? String == AgentPaneModel.gitWriteFailedMessage)
        #expect((error["details"] as? [String: Any])?["reason"] as? String == "rejected_non_fast_forward")
        model.onGitWrite = { _ in throw AgentPaneGitFailure.timedOut }
        reply = await model.respond(to: .gitWrite(.push(cwd: "/repo", expectedHead: nil, key: Self.key)))
        error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "native.timed_out")
        #expect(error["origin"] as? String == "native")
    }

    /// Without a session host nothing is sent; refused params never reach it.
    @Test func noHostOrInvalidParamsAreNeverSent() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var reply = await model.respond(to: .gitWrite(.push(cwd: "/repo", expectedHead: nil, key: Self.key)))
        var error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "native.not_connected")
        #expect(error["userMessage"] as? String == AgentPaneModel.gitWriteFailedMessage)
        var asked = 0
        model.onGitWrite = { _ in
            asked += 1
            return Data("{}".utf8)
        }
        reply = await model.respond(to: Self.request("git.commit", ["cwd": "/repo", "idempotency_key": Self.key]))
        error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "native.invalid_request")
        #expect(error["userMessage"] as? String == AgentPaneModel.gitWriteFailedMessage)
        #expect(asked == 0)
    }
}
