import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// How the agent pane's checkpoint requests reach the session host and how
/// their answers reach the page: params with the folder as `path`, the
/// mutation key in the envelope, the page's mutation envelope, the
/// capability answer, and which failures stay uncertain.
@MainActor
struct AgentPaneCheckpointForwardTests {
    @Test func theFolderIsThePathAndAMutationsKeyIsNotAParam() {
        let options = AgentPaneCheckpointCreate(
            expectedRepositoryID: "repo_1", expectedWorktreeID: "wt_1", includeUntracked: .paths(["notes.md"]),
            excludePaths: ["build"], reason: .manual, limits: AgentPaneCheckpointCreate.Limits(maxBytes: 4096))
        let create = AgentPaneGitRequest.checkpoint(.create(cwd: "/repo", options: options, idempotencyKey: "key-1"))
        #expect(create.operation == "git.checkpoint.create")
        #expect(create.idempotencyKey == "key-1")
        #expect(create.sessionHostParams == [
            "path": .string("/repo"), "expected_repository_id": .string("repo_1"), "expected_worktree_id": .string("wt_1"),
            "include_untracked": .array([.string("notes.md")]), "exclude_paths": .array([.string("build")]),
            "reason": .string("manual"), "limits": .object(["max_bytes": .number(4096)])
        ])
        let eligible = AgentPaneGitRequest.checkpoint(
            .create(cwd: "/repo", options: AgentPaneCheckpointCreate(includeUntracked: .eligible), idempotencyKey: "k"))
        #expect(eligible.sessionHostParams == ["path": .string("/repo"), "include_untracked": .string("eligible")])

        let pin = AgentPaneGitRequest.checkpoint(
            .pin(cwd: "/repo", checkpointID: "cp_1", pinID: "user:1", reason: "manual", idempotencyKey: "key-2"))
        #expect(pin.idempotencyKey == "key-2")
        #expect(pin.sessionHostParams == [
            "path": .string("/repo"), "checkpoint_id": .string("cp_1"), "pin_id": .string("user:1"), "reason": .string("manual")
        ])
        let unpin = AgentPaneGitRequest.checkpoint(
            .unpin(cwd: "/repo", checkpointID: "cp_1", pinID: "user:1", idempotencyKey: "key-3"))
        #expect(unpin.idempotencyKey == "key-3")
        #expect(unpin.sessionHostParams == ["path": .string("/repo"), "checkpoint_id": .string("cp_1"), "pin_id": .string("user:1")])
    }

    /// A get by key carries the key as its lookup field; a read has no
    /// envelope key.
    @Test func aGetByKeyCarriesTheKeyAsAField() {
        let byKey = AgentPaneGitRequest.checkpoint(.get(cwd: "/repo", lookup: .idempotencyKey("key-1")))
        #expect(byKey.idempotencyKey == nil)
        #expect(byKey.sessionHostParams == ["path": .string("/repo"), "idempotency_key": .string("key-1")])
        let byID = AgentPaneGitRequest.checkpoint(.get(cwd: "/repo", lookup: .checkpointID("cp_1")))
        #expect(byID.sessionHostParams == ["path": .string("/repo"), "checkpoint_id": .string("cp_1")])
        let list = AgentPaneGitRequest.checkpoint(.list(cwd: "/repo", cursor: "c2", limit: 25, includeCandidates: true))
        #expect(list.idempotencyKey == nil)
        #expect(list.sessionHostParams == [
            "path": .string("/repo"), "cursor": .string("c2"), "limit": .number(25), "include_candidates": .bool(true)
        ])
    }

    /// The page's `mutationEnvelope` reads `{result, revision, replayed}`;
    /// the catalog's `MutationResult` names the record `value`.
    @Test func aMutationRepliesWithThePagesEnvelope() throws {
        let line = #"{"value":{"checkpoint_id":"cp_1","revision":"7"},"generation":"g1","revision":"7","replayed":true}"#
        let reply = try JSONDecoder().decode(ResourceMutationResult<JSONValue>.self, from: Data(line.utf8))
        let page = try JSONDecoder().decode(JSONValue.self, from: AgentPaneGitLink.pageEnvelope(reply))
        #expect(page == .object([
            "result": .object(["checkpoint_id": .string("cp_1"), "revision": .string("7")]),
            "revision": .string("7"),
            "replayed": .bool(true)
        ]))
    }

    @Test func capabilitiesFollowTheDaemonsIdentify() throws {
        func checkpoints(_ data: Data) throws -> JSONValue? {
            guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            return object["checkpoints"]
        }
        #expect(try checkpoints(AgentPaneGitLink.capabilitiesReply(DaemonIdentity(capabilities: ["git-checkpoints-v1"], generation: "g"))) == .bool(true))
        #expect(try checkpoints(AgentPaneGitLink.capabilitiesReply(DaemonIdentity(capabilities: ["sidebar-layout-v1"], generation: "g"))) == .bool(false))
        #expect(try checkpoints(AgentPaneGitLink.capabilitiesReply(nil)) == .bool(false))
    }

    /// A daemon the link cannot reach serves no checkpoints: the answer is
    /// false, not a failure. A checkpoint request to it was never sent.
    @Test func anUnreachableDaemonServesNoCheckpoints() async throws {
        let link = AgentPaneGitLink(endpoint: { throw DaemonError.notConnected })
        let data = try await link.run(.capabilities)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == .object(["checkpoints": .bool(false)]))
        await #expect(throws: AgentPaneGitFailure.notConnected) {
            try await link.run(.checkpoint(.unpin(cwd: "/repo", checkpointID: "cp_1", pinID: "user:1", idempotencyKey: "k")))
        }
    }

    /// A mutation that may have reached the session host stays uncertain
    /// (`native.timed_out`, origin native): the page looks the key up before
    /// it retries. Only a refusal before sending or the session host's own
    /// answer is definite.
    @Test func aMutationWithNoAnswerIsUncertain() {
        #expect(AgentPaneGitFailure(mutating: DaemonError.timedOut("git.checkpoint.create")) == .timedOut)
        #expect(AgentPaneGitFailure(mutating: DaemonError.connectionClosed(reason: "EOF")) == .timedOut)
        #expect(AgentPaneGitFailure(mutating: DaemonError.daemonShutdown) == .timedOut)
        #expect(AgentPaneGitFailure(mutating: DaemonError.malformedResponse("MutationResult")) == .timedOut)
        #expect(AgentPaneGitFailure(mutating: CancellationError()) == .timedOut)
        #expect(AgentPaneGitFailure.timedOut.origin == .native)
        #expect(AgentPaneGitFailure(mutating: DaemonError.notConnected) == .notConnected)
        #expect(AgentPaneGitFailure(mutating: DaemonError.command(cmd: "git.checkpoint.pin", message: "no", code: nil)) == .failed)
    }

    @Test func aSessionHostErrorOfAMutationKeepsItsCodeDetailsAndRetryable() throws {
        let failure = AgentPaneGitFailure(mutating: DaemonError.command(
            cmd: "git.checkpoint.unpin", message: "managed", code: "operation.failed",
            details: .object(["reason": .string("managed_pin")]), retryable: false))
        #expect(failure.origin == .sessionHost)
        #expect(failure.code == "operation.failed")
        #expect(failure.retryable == false)
        let details = try #require(failure.details)
        #expect(try JSONDecoder().decode(JSONValue.self, from: details) == .object(["reason": .string("managed_pin")]))
        let indeterminate = AgentPaneGitFailure(mutating: DaemonError.command(
            cmd: "git.checkpoint.create", message: "unknown", code: "mutation.indeterminate", retryable: true))
        #expect(indeterminate == AgentPaneGitFailure(code: "mutation.indeterminate", details: nil, retryable: true, origin: .sessionHost))
    }
}
