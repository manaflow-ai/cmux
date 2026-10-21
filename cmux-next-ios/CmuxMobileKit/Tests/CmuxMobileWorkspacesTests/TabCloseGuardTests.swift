import CmuxMobileModel
import Testing
@testable import CmuxMobileWorkspaces

/// T-TABS-08 (round 11 N2/A1): closing a tab asks exactly as the cmux-next Mac
/// app does (`TabCloseGuard` there): a working agent in a closing terminal,
/// else a foreground program other than the login shell, read from the Mac's
/// `process-info`, never guessed from the title.
@Suite struct TabCloseGuardTests {
    let guardrail = TabCloseGuard()

    @Test func aForegroundProgramIsReadFromTheMacNotTheTitle() {
        #expect(TabCloseGuard.runningProgram(foregroundExecutable: "sleep", command: nil) == "sleep")
        #expect(TabCloseGuard.runningProgram(foregroundExecutable: "/usr/bin/yes", command: nil) == "yes")
        #expect(TabCloseGuard.runningProgram(foregroundExecutable: "codex", command: nil) == "codex")
        #expect(TabCloseGuard.runningProgram(foregroundExecutable: "git", command: nil) == "git")
    }

    @Test func theLoginShellIsIdle() {
        #expect(TabCloseGuard.runningProgram(foregroundExecutable: "zsh", command: nil) == nil)
        #expect(TabCloseGuard.runningProgram(foregroundExecutable: "-zsh", command: nil) == nil)
        #expect(TabCloseGuard.runningProgram(foregroundExecutable: "/bin/bash", command: "/bin/bash -l") == nil)
        #expect(TabCloseGuard.runningProgram(foregroundExecutable: nil, command: nil) == nil)
        #expect(TabCloseGuard.runningProgram(foregroundExecutable: "", command: nil) == nil)
    }

    @Test func aRunningProgramAsksWithTheMacsWords() throws {
        let tab = WorkspaceTab(id: "t", kind: .terminal, title: "sleep 6135")
        let prompt = try #require(guardrail.prompt(closing: [tab], programs: ["sleep"]))
        #expect(prompt.title == "Close \u{201C}sleep 6135\u{201D}?")
        #expect(prompt.message == "Still running: sleep.")
    }

    /// Round 11 sample 6: an idle Codex named by its thread ("Reply V11MARK-6607 | cmux") was
    /// closed with no question. Its foreground program is still `codex`.
    @Test func anIdleCodexTitledByItsThreadAsks() throws {
        let tab = WorkspaceTab(id: "t", kind: .terminal, title: "Reply V11MARK-6607 | cmux", agentStatus: .waiting)
        let prompt = try #require(guardrail.prompt(closing: [tab], programs: ["codex"]))
        #expect(prompt.message == "Still running: codex.")
    }

    @Test func aWorkingAgentIsTheAgentsQuestion() throws {
        let tab = WorkspaceTab(id: "t", kind: .terminal, title: "⠹ Reply", harness: "codex", agentStatus: .working)
        #expect(guardrail.workingAgent(tab) == "Codex")
        let prompt = try #require(guardrail.prompt(closing: [tab], programs: []))
        #expect(prompt.message == "Codex is still working.")
        // The agent's terminals are not asked what they run.
        #expect(guardrail.terminalsToAsk([tab]).isEmpty)
    }

    @Test func anAgentAskingPermissionCountsAsWorking() {
        let tab = WorkspaceTab(id: "t", kind: .terminal, title: "claude", harness: "claude", agentStatus: .waiting,
                               waitingFor: .permission)
        #expect(guardrail.workingAgent(tab) == "Claude")
    }

    @Test func anIdleShellOrABrowserClosesAtOnce() {
        let shell = WorkspaceTab(id: "a", kind: .terminal, title: "codex")
        let page = WorkspaceTab(id: "b", kind: .browser, title: "vim")
        #expect(guardrail.prompt(closing: [shell], programs: []) == nil)
        #expect(guardrail.prompt(closing: [page], programs: []) == nil)
        #expect(guardrail.terminalsToAsk([shell, page]).map(\.id) == ["a"])
    }

    @Test func aGroupAsksOnceForAllItsPrograms() throws {
        let tabs = [WorkspaceTab(id: "a", kind: .terminal, title: "one"), WorkspaceTab(id: "b", kind: .terminal, title: "two")]
        let prompt = try #require(guardrail.prompt(closing: tabs, programs: ["yes", "sleep", "yes"]))
        #expect(prompt.title == "Close 2 tabs?")
        #expect(prompt.message == "Still running: sleep, yes.")
    }

    @Test func anEndedShellNeverAsks() {
        var tab = WorkspaceTab(id: "a", kind: .terminal, title: "sleep")
        tab.shellEnded = true
        #expect(guardrail.terminalsToAsk([tab]).isEmpty)
    }
}
