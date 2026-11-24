@testable import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemonService

/// A new worktree chat's setup line (design/worktree-setup.md) reads `git.worktree.setup` with
/// `{path, since?}`: the App passes the folder and the output offset to the session host, and
/// refuses an offset that is not a decimal string rather than read from the start again.
struct AgentPaneWorktreeSetupTests {
    @Test func theSetupReadReachesTheSessionHostWithItsOffset() throws {
        let first = try #require(AgentPaneGitRequest(method: "git.worktree.setup", params: ["path": "/w/fix-login"]))
        #expect(first.operation == "git.worktree.setup")
        #expect(first.sessionHostParams == ["path": .string("/w/fix-login")])
        let next = try #require(AgentPaneGitRequest(method: "git.worktree.setup", params: ["path": "/w/fix-login", "since": "1024"]))
        #expect(next.sessionHostParams == ["path": .string("/w/fix-login"), "since": .string("1024")])
        #expect(AgentPaneRequest(body: ["method": "git.worktree.setup", "params": ["path": "/w/fix-login"]]) == .git(first))
    }

    @Test func aRelativeFolderOrABadOffsetIsRefused() {
        #expect(AgentPaneGitRequest(method: "git.worktree.setup", params: ["path": "w/fix-login"]) == nil)
        #expect(AgentPaneGitRequest(method: "git.worktree.setup", params: ["path": "/w", "since": 10]) == nil)
        #expect(AgentPaneGitRequest(method: "git.worktree.setup", params: ["path": "/w", "since": "-1"]) == nil)
    }
}
