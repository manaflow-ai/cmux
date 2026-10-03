import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A host whose daemon knows one session's folder.
private struct FolderHost: AgentPaneHostProviding {
    var folders: [String: AgentPaneSessionFolder] = [:]
    var unreachable = false
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? {
        if unreachable { throw AgentPaneHostError.daemonStopped }
        return folders[sessionId]
    }
}

/// `git.commit` and `git.push` from the changes view: which params the host
/// accepts, where it runs them, and how the model answers the page.
@MainActor
@Suite struct AgentPaneGitWriteTests {
    private static let key = "6f1c2a3e-0b4d-4e5f-8a9b-0c1d2e3f4a5b"
    private static let head = "4be1c2e9a0f1b2c3d4e5f60718293a4b5c6d7e8f"

    private static func request(_ method: String, _ params: [String: Any]) -> AgentPaneRequest {
        AgentPaneRequest(body: ["method": method, "params": params] as [String: Any])
    }

    /// A model showing session `s1`, whose daemon folder is `/repo`.
    private static func model(_ host: FolderHost = FolderHost(folders: ["s1": AgentPaneSessionFolder(cwd: "/repo", isLocal: true)])) async -> AgentPaneModel {
        let model = AgentPaneModel(host: host)
        _ = await model.respond(to: .persistSession("s1"))
        return model
    }

    @Test func aCommitCarriesTheMessageScopeHeadAndKey() {
        #expect(Self.request("git.commit", ["message": "Fix upload", "idempotency_key": Self.key])
            == .gitWrite(.commit(message: "Fix upload", all: false, includeUntracked: false, expectedHead: nil, key: Self.key)))
        let all = Self.request("git.commit", [
            "cwd": "/elsewhere", "message": "Fix\n\nBody", "all": true, "include_untracked": true,
            "expected_head": Self.head, "idempotency_key": Self.key,
        ])
        #expect(all == .gitWrite(.commit(message: "Fix\n\nBody", all: true, includeUntracked: true, expectedHead: Self.head, key: Self.key)))
        let write = AgentPaneGitWrite.commit(message: "m", all: false, includeUntracked: false, expectedHead: nil, key: Self.key)
        #expect(write.operation == "git.commit")
        #expect(write.key == Self.key)
    }

    /// "All" without "Include new files" is `git commit -a`: an untracked
    /// file such as `.env` is not staged, because the request says nothing
    /// about untracked files.
    @Test func allWithoutNewFilesCarriesNoUntrackedFlag() {
        let request = Self.request("git.commit", ["message": "m", "all": true, "idempotency_key": Self.key])
        #expect(request == .gitWrite(.commit(message: "m", all: true, includeUntracked: false, expectedHead: nil, key: Self.key)))
    }

    @Test func aPushCarriesTheHeadAndKey() {
        #expect(Self.request("git.push", ["expected_head": Self.head, "idempotency_key": Self.key])
            == .gitWrite(.push(expectedHead: Self.head, key: Self.key)))
        #expect(Self.request("git.push", ["idempotency_key": Self.key]) == .gitWrite(.push(expectedHead: nil, key: Self.key)))
        #expect(AgentPaneGitWrite.push(expectedHead: nil, key: Self.key).operation == "git.push")
    }

    /// Params the session host would refuse, or the page should never send,
    /// stop at the bridge: no key, an empty or blank message, one over
    /// 64 KiB, untracked files without All, a head that is not a commit id,
    /// or a flag that is not a boolean.
    @Test func invalidParamsAreAnInvalidRequest() {
        let base: [String: Any] = ["message": "m", "idempotency_key": Self.key]
        let broken: [[String: Any]] = [
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
        #expect(Self.request("git.push", [:]) == .invalidGit("git.push"))
        #expect(Self.request("git.push", ["idempotency_key": Self.key, "expected_head": "main"]) == .invalidGit("git.push"))
    }

    /// The write runs in the folder the daemon reports for the pane's own
    /// session, never in a `cwd` the page sent.
    @Test func theWriteRunsInThePanesSessionFolder() async throws {
        let model = await Self.model()
        var asked: [(AgentPaneGitWrite, String)] = []
        model.onGitWrite = { request, cwd in
            asked.append((request, cwd))
            return Data(#"{"value":{"root":"/repo","commit":"abcd1234","summary":"Fix","files_changed":1,"additions":2,"deletions":0},"generation":"g","revision":3,"replayed":false}"#.utf8)
        }
        let reply = await model.respond(to: Self.request("git.push", ["cwd": "/other/repo", "idempotency_key": Self.key]))
        #expect(reply["ok"] as? Bool == true)
        let value = try #require(reply["value"] as? [String: Any])
        #expect((value["value"] as? [String: Any])?["commit"] as? String == "abcd1234")
        #expect(asked.count == 1)
        #expect(asked.first?.0 == .push(expectedHead: nil, key: Self.key))
        #expect(asked.first?.1 == "/repo")
    }

    /// No session, a session the daemon does not know, another machine's
    /// session, or an unreachable daemon: nothing is sent.
    @Test func withoutALocalSessionFolderNothingIsSent() async throws {
        let hosts: [(FolderHost, Bool, String)] = [
            (FolderHost(), true, "native.no_session_folder"),
            (FolderHost(folders: ["s1": AgentPaneSessionFolder(cwd: "/vm/repo", isLocal: false)]), true, "native.no_session_folder"),
            (FolderHost(unreachable: true), true, "native.not_connected"),
            (FolderHost(folders: ["s1": AgentPaneSessionFolder(cwd: "/repo", isLocal: true)]), false, "native.no_session_folder"),
        ]
        for (host, persisted, code) in hosts {
            let model: AgentPaneModel
            if persisted { model = await Self.model(host) } else { model = AgentPaneModel(host: host) }
            var asked = 0
            model.onGitWrite = { _, _ in
                asked += 1
                return Data("{}".utf8)
            }
            let reply = await model.respond(to: .gitWrite(.push(expectedHead: nil, key: Self.key)))
            let error = try #require(reply["error"] as? [String: Any])
            #expect(error["code"] as? String == code)
            #expect(error["origin"] as? String == "native")
            #expect(error["userMessage"] as? String == AgentPaneModel.gitWriteFailedMessage)
            #expect(asked == 0)
        }
    }

    /// A refusal keeps the session host's machine reason in `details`, under
    /// the write's own localized text; a lost reply is `native.timed_out`.
    @Test func aFailedWriteKeepsTheReasonUnderTheWriteText() async throws {
        let model = await Self.model()
        model.onGitWrite = { _, _ in
            throw AgentPaneGitFailure(
                code: "operation.failed",
                details: Data(#"{"operation":"git.push","reason":"rejected_non_fast_forward","extra":{"message":"behind"}}"#.utf8),
                retryable: false, origin: .sessionHost)
        }
        var reply = await model.respond(to: .gitWrite(.push(expectedHead: nil, key: Self.key)))
        var error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "operation.failed")
        #expect(error["origin"] as? String == "session_host")
        #expect(error["userMessage"] as? String == AgentPaneModel.gitWriteFailedMessage)
        #expect((error["details"] as? [String: Any])?["reason"] as? String == "rejected_non_fast_forward")
        model.onGitWrite = { _, _ in throw AgentPaneGitFailure.timedOut }
        reply = await model.respond(to: .gitWrite(.push(expectedHead: nil, key: Self.key)))
        error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "native.timed_out")
        #expect(error["origin"] as? String == "native")
    }

    /// Without a session host link nothing is sent; refused params never reach it.
    @Test func noLinkOrInvalidParamsAreNeverSent() async throws {
        let model = await Self.model()
        var reply = await model.respond(to: .gitWrite(.push(expectedHead: nil, key: Self.key)))
        var error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "native.not_connected")
        #expect(error["userMessage"] as? String == AgentPaneModel.gitWriteFailedMessage)
        var asked = 0
        model.onGitWrite = { _, _ in
            asked += 1
            return Data("{}".utf8)
        }
        reply = await model.respond(to: Self.request("git.commit", ["idempotency_key": Self.key]))
        error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "native.invalid_request")
        #expect(error["userMessage"] as? String == AgentPaneModel.gitWriteFailedMessage)
        #expect(asked == 0)
    }

    /// The session list entry for the pane's session names its folder and
    /// whether it is on this Mac.
    @Test func theSessionFolderComesFromTheDaemonsSessionList() {
        let sessions: [[String: Any]] = [
            ["sessionId": "a", "cwd": "/repo/a", "hostKind": "local"],
            ["sessionId": "b", "cwd": "/vm/b", "hostKind": "cloud"],
            ["sessionId": "c"],
        ]
        #expect(AgentPaneSessionFolder(sessionId: "a", in: sessions) == AgentPaneSessionFolder(cwd: "/repo/a", isLocal: true))
        #expect(AgentPaneSessionFolder(sessionId: "b", in: sessions) == AgentPaneSessionFolder(cwd: "/vm/b", isLocal: false))
        #expect(AgentPaneSessionFolder(sessionId: "c", in: sessions) == nil)
        #expect(AgentPaneSessionFolder(sessionId: "z", in: sessions) == nil)
        #expect(AgentPaneSessionFolder(sessionId: "a", in: nil) == nil)
    }
}
