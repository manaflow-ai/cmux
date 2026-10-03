import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

private struct SomethingElse: Error {}

/// How a failed git read of the agent pane's changes view reaches the page:
/// the session host's resource error verbatim, or a native code saying why
/// the request got no answer.
@MainActor
struct AgentPaneGitReadsTests {
    @Test func aSessionHostErrorKeepsItsCodeDetailsAndRetryable() throws {
        let failure = AgentPaneGitFailure(reading: DaemonError.command(
            cmd: "git.diff", message: "not a git repository", code: "operation.failed",
            details: .object(["exit_code": .number(128)]), retryable: false))
        #expect(failure.origin == .sessionHost)
        #expect(failure.code == "operation.failed")
        #expect(failure.retryable == false)
        let details = try #require(failure.details)
        #expect(try JSONDecoder().decode(JSONValue.self, from: details) == .object(["exit_code": .number(128)]))
        let bare = AgentPaneGitFailure(reading: DaemonError.command(cmd: "git.status", message: "gone", code: "resource.not_found"))
        #expect(bare == AgentPaneGitFailure(code: "resource.not_found", details: nil, retryable: nil, origin: .sessionHost))
    }

    /// A commit or push names the folder as `path` and sends only the
    /// fields the page set; the key rides in the envelope, not the params.
    @Test func aWriteSendsTheFolderAsPathAndOnlyTheFieldsItSet() {
        let commit = AgentPaneGitWrite.commit(
            cwd: "/repo", message: "Fix", all: true, includeUntracked: true, expectedHead: "abcd1234", key: "k")
        #expect(commit.sessionHostParams == [
            "path": .string("/repo"), "message": .string("Fix"), "all": .bool(true),
            "include_untracked": .bool(true), "expected_head": .string("abcd1234"),
        ])
        let staged = AgentPaneGitWrite.commit(cwd: "/repo", message: "Fix", all: false, includeUntracked: false, expectedHead: nil, key: "k")
        #expect(staged.sessionHostParams == ["path": .string("/repo"), "message": .string("Fix")])
        #expect(AgentPaneGitWrite.push(cwd: "/repo", expectedHead: nil, key: "k").sessionHostParams == ["path": .string("/repo")])
        #expect(AgentPaneGitWrite.push(cwd: "/repo", expectedHead: "abcd1234", key: "k").sessionHostParams
            == ["path": .string("/repo"), "expected_head": .string("abcd1234")])
    }

    @Test func aRequestWithNoAnswerGetsANativeCode() {
        #expect(AgentPaneGitFailure(reading: DaemonError.notConnected) == .notConnected)
        #expect(AgentPaneGitFailure(reading: DaemonError.timedOut("git.diff")) == .timedOut)
        #expect(AgentPaneGitFailure(reading: DaemonError.connectionClosed(reason: "EOF")) == .timedOut)
        #expect(AgentPaneGitFailure(reading: DaemonError.daemonShutdown) == .timedOut)
        #expect(AgentPaneGitFailure(reading: DaemonError.malformedResponse("JSONValue")) == .failed)
        #expect(AgentPaneGitFailure(reading: DaemonError.command(cmd: "git.diff", message: "no code", code: nil)) == .failed)
        #expect(AgentPaneGitFailure(reading: SomethingElse()) == .failed)
        #expect(AgentPaneGitFailure(reading: AgentPaneGitFailure.invalidRequest) == .invalidRequest)
    }
}
