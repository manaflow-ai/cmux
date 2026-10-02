import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The checkpoint review's requests (`git.capabilities`, `git.checkpoint.*`)
/// exactly as the page's checkpoint client sends them: which params the
/// bridge accepts, and how the model answers.
@MainActor
@Suite struct AgentPaneCheckpointRequestTests {
    /// The page's message with `params` as JSON text, bridged the way
    /// WebKit bridges a JavaScript object: numbers and booleans become
    /// `NSNumber`s, `null` becomes `NSNull`.
    private static func request(_ method: String, _ params: String) -> AgentPaneRequest {
        let object = try? JSONSerialization.jsonObject(with: Data(params.utf8))
        return AgentPaneRequest(body: ["method": method, "params": object ?? NSNull()] as [String: Any])
    }

    private static func checkpoint(_ method: String, _ params: String) -> AgentPaneCheckpointRequest? {
        guard case .git(.checkpoint(let checkpoint)) = request(method, params) else { return nil }
        return checkpoint
    }

    @Test func capabilitiesTakeNoParams() {
        #expect(Self.request("git.capabilities", "{}") == .git(.capabilities))
        #expect(AgentPaneRequest(body: ["method": "git.capabilities"] as [String: Any]) == .git(.capabilities))
        #expect(Self.request("git.capabilities", #"{"cwd":"/repo"}"#) == .invalidGit("git.capabilities"))
        #expect(AgentPaneGitRequest.capabilities.cwd == nil)
        #expect(AgentPaneGitRequest.capabilities.idempotencyKey == nil)
    }

    /// The review's create: the checked paths, the identity the list read
    /// returned, and the key the client keeps across an uncertain reply.
    @Test func aCreateCarriesItsFieldsAndItsEnvelopeKey() throws {
        let create = try #require(Self.checkpoint("git.checkpoint.create", """
            {"cwd":"/repo","include_untracked":["notes.md","dir/a b.txt"],"expected_repository_id":"repo_1",
             "expected_worktree_id":"wt_1","reason":"manual","idempotency_key":"key-1"}
            """))
        let options = AgentPaneCheckpointCreate(
            expectedRepositoryID: "repo_1", expectedWorktreeID: "wt_1", includeUntracked: .paths(["notes.md", "dir/a b.txt"]),
            reason: .manual)
        #expect(create == .create(cwd: "/repo", options: options, idempotencyKey: "key-1"))
        #expect(create.operation == "git.checkpoint.create")
        #expect(create.idempotencyKey == "key-1")
        #expect(AgentPaneGitRequest.checkpoint(create).idempotencyKey == "key-1")
        #expect(AgentPaneGitRequest.checkpoint(create).cwd == "/repo")

        let everything = try #require(Self.checkpoint("git.checkpoint.create", """
            {"cwd":"/repo","include_untracked":"eligible","exclude_paths":["build"],"reason":"handoff",
             "limits":{"max_bytes":1000000,"max_files":20},"idempotency_key":"key-2"}
            """))
        let all = AgentPaneCheckpointCreate(
            includeUntracked: .eligible, excludePaths: ["build"], reason: .handoff,
            limits: AgentPaneCheckpointCreate.Limits(maxBytes: 1_000_000, maxFiles: 20))
        #expect(everything == .create(cwd: "/repo", options: all, idempotencyKey: "key-2"))
        #expect(Self.checkpoint("git.checkpoint.create", #"{"cwd":"/repo","include_untracked":[],"idempotency_key":"k"}"#)
            == .create(cwd: "/repo", options: AgentPaneCheckpointCreate(includeUntracked: .paths([])), idempotencyKey: "k"))
        #expect(Self.checkpoint("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"k"}"#)
            == .create(cwd: "/repo", options: AgentPaneCheckpointCreate(), idempotencyKey: "k"))
    }

    /// A get names one record: by id, or by the key a create used (a lookup
    /// field, so the request itself has no envelope key).
    @Test func aGetLooksUpByIDOrByKey() {
        #expect(Self.checkpoint("git.checkpoint.get", #"{"cwd":"/repo","checkpoint_id":"cp_1"}"#)
            == .get(cwd: "/repo", lookup: .checkpointID("cp_1")))
        let byKey = Self.checkpoint("git.checkpoint.get", #"{"cwd":"/repo","idempotency_key":"key-1"}"#)
        #expect(byKey == .get(cwd: "/repo", lookup: .idempotencyKey("key-1")))
        #expect(byKey?.idempotencyKey == nil)
    }

    @Test func aListPinAndUnpinCarryTheirFields() {
        #expect(Self.checkpoint("git.checkpoint.list", #"{"cwd":"/repo","include_candidates":true}"#)
            == .list(cwd: "/repo", cursor: nil, limit: nil, includeCandidates: true))
        #expect(Self.checkpoint("git.checkpoint.list", #"{"cwd":"/repo","cursor":"c2","limit":25}"#)
            == .list(cwd: "/repo", cursor: "c2", limit: 25, includeCandidates: nil))
        #expect(Self.checkpoint("git.checkpoint.list", #"{"cwd":"/repo"}"#)
            == .list(cwd: "/repo", cursor: nil, limit: nil, includeCandidates: nil))
        let pin = Self.checkpoint("git.checkpoint.pin",
            #"{"cwd":"/repo","checkpoint_id":"cp_1","pin_id":"user:1","reason":"manual","idempotency_key":"key-3"}"#)
        #expect(pin == .pin(cwd: "/repo", checkpointID: "cp_1", pinID: "user:1", reason: "manual", idempotencyKey: "key-3"))
        #expect(pin?.idempotencyKey == "key-3")
        let unpin = Self.checkpoint("git.checkpoint.unpin",
            #"{"cwd":"/repo","checkpoint_id":"cp_1","pin_id":"user:1","idempotency_key":"key-4"}"#)
        #expect(unpin == .unpin(cwd: "/repo", checkpointID: "cp_1", pinID: "user:1", idempotencyKey: "key-4"))
    }

    /// Anything the page's client would not send never reaches the session
    /// host: it is `invalidGit`, answered `native.invalid_request`.
    @Test(arguments: [
        // No folder, a relative folder, a NUL.
        ("git.checkpoint.list", #"{"include_candidates":true}"#),
        ("git.checkpoint.list", #"{"cwd":"repo"}"#),
        ("git.checkpoint.get", #"{"cwd":"/repo\u0000","checkpoint_id":"cp_1"}"#),
        // A field the operation does not take.
        ("git.checkpoint.list", #"{"cwd":"/repo","scope":"staged"}"#),
        ("git.checkpoint.get", #"{"cwd":"/repo","checkpoint_id":"cp_1","sessionId":"s"}"#),
        // Wrong types.
        ("git.checkpoint.list", #"{"cwd":"/repo","include_candidates":"yes"}"#),
        ("git.checkpoint.list", #"{"cwd":"/repo","include_candidates":1}"#),
        ("git.checkpoint.list", #"{"cwd":"/repo","limit":0}"#),
        ("git.checkpoint.list", #"{"cwd":"/repo","limit":2.5}"#),
        ("git.checkpoint.list", #"{"cwd":"/repo","limit":true}"#),
        ("git.checkpoint.list", #"{"cwd":"/repo","cursor":""}"#),
        // A get needs exactly one lookup.
        ("git.checkpoint.get", #"{"cwd":"/repo"}"#),
        ("git.checkpoint.get", #"{"cwd":"/repo","checkpoint_id":"cp_1","idempotency_key":"k"}"#),
        // A mutation needs its key, and a well-formed one.
        ("git.checkpoint.create", #"{"cwd":"/repo","include_untracked":[]}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":""}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"\#(String(repeating: "k", count: 129))"}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"a\nb"}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":7}"#),
        // Create fields.
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"k","include_untracked":"all"}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"k","include_untracked":["a",3]}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"k","include_untracked":[""]}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"k","reason":"later"}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"k","limits":{"max_bytes":-1}}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"k","limits":{"max_lines":3}}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"k","exclude_paths":"build"}"#),
        ("git.checkpoint.create", #"{"cwd":"/repo","idempotency_key":"k","expected_repository_id":4}"#),
        // Pin and unpin fields.
        ("git.checkpoint.pin", #"{"cwd":"/repo","checkpoint_id":"cp_1","pin_id":"p","idempotency_key":"k"}"#),
        ("git.checkpoint.pin", #"{"cwd":"/repo","pin_id":"p","reason":"r","idempotency_key":"k"}"#),
        ("git.checkpoint.unpin", #"{"cwd":"/repo","checkpoint_id":"cp_1","idempotency_key":"k"}"#),
        ("git.checkpoint.unpin", #"{"cwd":"/repo","checkpoint_id":"cp_1","pin_id":"p","reason":"r","idempotency_key":"k"}"#),
        ("git.checkpoint.unpin", #"{"cwd":"/repo","checkpoint_id":"cp_1","pin_id":"p"}"#)
    ])
    func aMalformedCheckpointRequestIsInvalid(method: String, params: String) {
        #expect(Self.request(method, params) == .invalidGit(method))
    }

    /// A JavaScript `null` (bridged as `NSNull`) is an absent field.
    @Test func aNullOptionalFieldIsAbsent() {
        #expect(Self.checkpoint("git.checkpoint.list", #"{"cwd":"/repo","cursor":null}"#)
            == .list(cwd: "/repo", cursor: nil, limit: nil, includeCandidates: nil))
    }

    /// No session host wired: the review hides its actions instead of
    /// showing an error.
    @Test func capabilitiesWithNoHostAreFalse() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        let reply = await model.respond(to: Self.request("git.capabilities", "{}"))
        #expect(reply["ok"] as? Bool == true)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["checkpoints"] as? Bool == false)
    }

    /// A mutation's `{result, revision, replayed}` reaches the page as the
    /// value, untouched.
    @Test func theModelRepliesWithTheMutationEnvelope() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        var asked: [AgentPaneGitRequest] = []
        model.onGit = { request in
            asked.append(request)
            return Data(#"{"result":{"checkpoint_id":"cp_1"},"revision":"7","replayed":true}"#.utf8)
        }
        let request = Self.request("git.checkpoint.unpin",
            #"{"cwd":"/repo","checkpoint_id":"cp_1","pin_id":"user:1","idempotency_key":"key-4"}"#)
        let reply = await model.respond(to: request)
        #expect(reply["ok"] as? Bool == true)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["revision"] as? String == "7")
        #expect(value["replayed"] as? Bool == true)
        #expect((value["result"] as? [String: Any])?["checkpoint_id"] as? String == "cp_1")
        #expect(asked == [.checkpoint(.unpin(cwd: "/repo", checkpointID: "cp_1", pinID: "user:1", idempotencyKey: "key-4"))])
    }

    /// A failed checkpoint request keeps the session host's fields under the
    /// checkpoint review's own failure text, not the changes view's.
    @Test func aCheckpointFailureKeepsItsFieldsUnderTheCheckpointText() async throws {
        let model = AgentPaneModel(host: MockAgentPaneHost())
        model.onGit = { _ in
            throw AgentPaneGitFailure(
                code: "mutation.indeterminate", details: Data(#"{"operation":"git.checkpoint.create"}"#.utf8),
                retryable: true, origin: .sessionHost)
        }
        let request = Self.request("git.checkpoint.create", #"{"cwd":"/repo","include_untracked":[],"idempotency_key":"k"}"#)
        let reply = await model.respond(to: request)
        #expect(reply["ok"] as? Bool == false)
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "mutation.indeterminate")
        #expect(error["origin"] as? String == "session_host")
        #expect(error["retryable"] as? Bool == true)
        #expect((error["details"] as? [String: Any])?["operation"] as? String == "git.checkpoint.create")
        #expect(error["userMessage"] as? String == AgentPaneModel.checkpointFailedMessage)

        let invalid = await model.respond(to: Self.request("git.checkpoint.pin", #"{"cwd":"/repo"}"#))
        let refusal = try #require(invalid["error"] as? [String: Any])
        #expect(refusal["code"] as? String == "native.invalid_request")
        #expect(refusal["origin"] as? String == "native")
        #expect(refusal["userMessage"] as? String == AgentPaneModel.checkpointFailedMessage)
    }
}
