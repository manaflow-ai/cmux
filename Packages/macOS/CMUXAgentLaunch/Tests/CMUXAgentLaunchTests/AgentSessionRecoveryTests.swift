import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent launcher prefix")
struct AgentLauncherPrefixTests {
    @Test("sr claude proxy keeps its account routing, not the forwarded resume args")
    func subrouterProxyPrefix() {
        // Shapes from the 2026-09-26 incident: sr forwards its tail to claude,
        // which the cmux wrapper extends with --settings/--mcp-config first.
        let parent = ["sr", "claude", "proxy", "--account", "me@example.com", "--resume", "655bc8de", "You're back."]
        let agent = ["/Users/me/.local/bin/claude", "--settings", "/tmp/s.json", "--mcp-config={}", "--resume", "655bc8de", "You're back."]
        #expect(
            AgentLauncherPrefix(kind: "claude").derive(agentArguments: agent, parentArguments: parent)
                == ["sr", "claude", "proxy", "--account", "me@example.com"]
        )
    }

    @Test("a launcher that forwards nothing keeps its whole argv")
    func launcherWithoutForwardedArgs() {
        #expect(
            AgentLauncherPrefix(kind: "claude").derive(
                agentArguments: ["/usr/local/bin/claude"],
                parentArguments: ["caffeinate", "-i", "claude"]
            ) == ["caffeinate", "-i", "claude"]
        )
    }

    @Test("shells and multiplexers are not launchers")
    func shellsAreNotLaunchers() {
        for parent in [["-zsh"], ["/bin/bash", "-lc", "claude"], ["tmux", "new", "claude"], ["/usr/bin/env", "claude"]] {
            #expect(
                AgentLauncherPrefix(kind: "claude").derive(agentArguments: ["claude"], parentArguments: parent) == nil
            )
        }
    }

    @Test("a parent that never names the agent is not trusted as its launcher")
    func unrelatedParentRejected() {
        #expect(
            AgentLauncherPrefix(kind: "claude").derive(
                agentArguments: ["claude", "--resume", "x"],
                parentArguments: ["node", "/opt/tool/index.js", "--resume", "x"]
            ) == nil
        )
    }
}

@Suite("Agent session recovery planner")
struct AgentSessionRecoveryPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_790_428_300)

    private func journal(_ id: String, _ kind: String, minutesAgo: Double, source: String = "claude") -> AgentRecoveryJournalSession {
        AgentRecoveryJournalSession(
            sessionId: id,
            source: source,
            lastOccurredAt: now.addingTimeInterval(-minutesAgo * 60),
            hasEnded: kind == "agent.session.ended"
        )
    }

    private func record(_ id: String, pid: Int = 100, prefix: [String]? = nil) -> AgentRecoveryLaunchRecord {
        AgentRecoveryLaunchRecord(
            kind: "claude",
            sessionId: id,
            workspaceId: "W-\(id)",
            cwd: "/Users/me/Projects/\(id)",
            launchCommand: AgentLaunchCommand(arguments: ["claude"], launcherPrefix: prefix),
            pid: pid,
            pidStartSeconds: 1,
            updatedAt: now.addingTimeInterval(-60)
        )
    }

    @Test("sessions killed with the app are recovered; ended, open, alive and stale ones are not")
    func selectsOnlyLostSessions() {
        let candidates = AgentSessionRecoveryPlanner().candidates(
            journal: [
                journal("lost-a", "agent.state.changed", minutesAgo: 2),
                journal("lost-b", "agent.turn.started", minutesAgo: 5),
                journal("ended", "agent.session.ended", minutesAgo: 3),
                journal("restored", "agent.turn.completed", minutesAgo: 3),
                journal("alive", "agent.turn.started", minutesAgo: 1),
                journal("stale", "agent.turn.started", minutesAgo: 60 * 72),
                journal("no-record", "agent.turn.started", minutesAgo: 1),
                journal("wrong-kind", "agent.turn.started", minutesAgo: 1, source: "codex"),
            ],
            records: ["lost-a", "lost-b", "ended", "restored", "stale", "wrong-kind"].map { record($0) }
                + [record("alive", pid: 999)],
            openSessionIds: ["restored"],
            isProcessAlive: { pid, _ in pid == 999 },
            now: now
        )
        #expect(candidates.map(\.sessionId) == ["lost-a", "lost-b"])
        #expect(candidates.first?.cwd == "/Users/me/Projects/lost-a")
        #expect(candidates.first?.workspaceId == "W-lost-a")
    }

    @Test("resume goes through the recorded launcher")
    func resumeUsesLauncherPrefix() throws {
        let candidates = AgentSessionRecoveryPlanner().candidates(
            journal: [journal("s1", "agent.turn.started", minutesAgo: 1), journal("s2", "agent.turn.started", minutesAgo: 2)],
            records: [record("s1", prefix: ["sr", "claude", "proxy", "--account", "me@example.com"]), record("s2")],
            openSessionIds: [],
            isProcessAlive: { _, _ in false },
            now: now
        )
        #expect(candidates.count == 2)
        #expect(candidates[0].launcherResumeArguments == ["sr", "claude", "proxy", "--account", "me@example.com", "--resume", "s1"])
        #expect(candidates[1].launcherResumeArguments == nil)
    }

    @Test("launch commands without a launcher prefix still decode")
    func legacyLaunchCommandDecodes() throws {
        let data = Data(#"{"arguments":["claude"],"launcher":"claude"}"#.utf8)
        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: data)
        #expect(command.launcherPrefix == nil)
    }
}
