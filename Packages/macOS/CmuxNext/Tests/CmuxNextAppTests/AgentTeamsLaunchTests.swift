import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Foundation
import Testing

/// Launch Claude Teams and Launch Codex Teams (`palette.launchClaudeTeams`,
/// `palette.launchCodexTeams`, `cmux agent launch-claude-teams|launch-codex-teams`): each opens a
/// new terminal tab that starts the agent with its team mode on, as classic `cmux claude-teams`
/// and `cmux codex-teams` did. They are working actions, not greyed-out rows.
@MainActor @Suite(.serialized)
struct AgentTeamsLaunchTests {
    static func services() -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]))
    }

    @Test(arguments: ["palette.launchClaudeTeams", "palette.launchCodexTeams"])
    func teamsLaunchersAreWorkingActions(id: String) {
        let services = Self.services()
        AppActions.bind(services)
        #expect(services.registry.unavailableReason(for: ActionID(rawValue: id)) == nil)
    }

    /// Claude Code runs its experimental agent teams with the teammates in the same terminal.
    @Test func claudeTeamsStartsClaudeWithAgentTeamsOn() {
        #expect(AgentTeamsLaunch.claude.shellLine
            == "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --teammate-mode in-process\n")
    }

    /// Codex runs its subagents (the multi-agent feature) in the root session.
    @Test func codexTeamsStartsCodexWithSubagentsOn() {
        #expect(AgentTeamsLaunch.codex.shellLine == "codex -c features.multi_agent=true\n")
    }

    @Test func eachLauncherIsBoundToItsAction() {
        #expect(AgentTeamsLaunch(actionID: "palette.launchClaudeTeams") == .claude)
        #expect(AgentTeamsLaunch(actionID: "palette.launchCodexTeams") == .codex)
        #expect(AgentTeamsLaunch(actionID: "palette.quickAgentChat") == nil)
    }

    /// Without a daemon there is no terminal to start the team in: the action says so.
    @Test(arguments: ["palette.launchClaudeTeams", "palette.launchCodexTeams"])
    func withoutADaemonTheLauncherRefusesWithTheReason(id: String) {
        let services = Self.services()
        AppActions.bind(services)
        let reason = services.registry.capturingRefusal {
            _ = services.registry.perform(ActionID(rawValue: id), invocation: ActionInvocation(origin: .cli))
        }
        #expect(reason == MiscHandlerStrings.daemonOffline)
    }
}
