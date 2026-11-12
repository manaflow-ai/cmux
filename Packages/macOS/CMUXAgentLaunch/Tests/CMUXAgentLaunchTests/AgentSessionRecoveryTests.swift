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

    @Test("a launcher argv carrying a credential is not recorded")
    func secretBearingLauncherRejected() {
        #expect(
            AgentLauncherPrefix(kind: "claude").derive(
                agentArguments: ["claude"],
                parentArguments: ["sr", "claude", "proxy", "--api-key", "sk-123"]
            ) == nil
        )
        for flag in [["--key", "sk-123"], ["--key=sk-123"], ["-k", "sk-123"]] {
            #expect(
                AgentLauncherPrefix(kind: "claude").derive(
                    agentArguments: ["claude"],
                    parentArguments: ["sr", "claude", "proxy"] + flag
                ) == nil
            )
        }
    }

    @Test("a launcher argv that still carries the old session's input is not recorded")
    func launcherCarryingSessionInputRejected() {
        // sr appended something after the forwarded tail, so no suffix matched.
        #expect(
            AgentLauncherPrefix(kind: "claude").derive(
                agentArguments: ["claude", "--resume", "old", "hi"],
                parentArguments: ["sr", "claude", "proxy", "--account", "me", "--resume", "old", "hi", "--extra"]
            ) == nil
        )
        #expect(!AgentLauncherPrefix.isReplayable(["sr", "claude", "proxy", "--continue"]))
        #expect(!AgentLauncherPrefix.isReplayable(["sr", "claude", "proxy", "--resume=old"]))
        #expect(AgentLauncherPrefix.isReplayable(["sr", "claude", "proxy", "--account", "me"]))
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
        // Preserved agent flags ride along after the launcher.
        var flagged = candidates[0]
        flagged.launchCommand?.arguments = ["claude", "--dangerously-skip-permissions", "--model", "opus"]
        let flaggedArguments = try #require(flagged.launcherResumeArguments)
        #expect(Array(flaggedArguments.prefix(7)) == ["sr", "claude", "proxy", "--account", "me@example.com", "--resume", "s1"])
        #expect(flaggedArguments.contains("--dangerously-skip-permissions"))
        #expect(flaggedArguments.contains("opus"))
        // A launcher declared in agents.launchers wins; the normal resume path applies it.
        var declared = candidates[0]
        declared.launchCommand?.externalLauncher = "sr"
        #expect(declared.launcherResumeArguments == nil)
        #expect(candidates[1].launcherResumeArguments == nil)
    }

    @Test("launcher resume drops stale settings files and defers routed or unsafe launches")
    func launcherResumeSanitizes() throws {
        let prefix = ["sr", "claude", "proxy", "--account", "me@example.com"]
        var candidate = AgentRecoveryCandidate(
            kind: "claude",
            sessionId: "s1",
            workspaceId: nil,
            cwd: "/tmp",
            launchCommand: AgentLaunchCommand(
                arguments: [
                    "claude",
                    "--settings", "/tmp/subrouter-claude-settings-abc/settings.json",
                    "--settings", "/tmp/gone.json",
                    "--settings", "/tmp/kept.json",
                    "--model", "opus",
                ],
                launcherPrefix: prefix
            ),
            lastActivity: now
        )
        let arguments = try #require(candidate.launcherResumeArguments(isReadableFile: { $0 == "/tmp/kept.json" }))
        #expect(Array(arguments.prefix(7)) == prefix + ["--resume", "s1"])
        #expect(!arguments.contains("/tmp/subrouter-claude-settings-abc/settings.json"))
        #expect(!arguments.contains("/tmp/gone.json"))
        #expect(arguments.contains("/tmp/kept.json"))
        #expect(arguments.contains("opus"))

        // A recorded prefix that selects a session itself is never replayed.
        candidate.launchCommand?.launcherPrefix = prefix + ["--resume", "old"]
        #expect(candidate.launcherResumeArguments(isReadableFile: { _ in true }) == nil)

        // A proven routed launch is left to `cmux restore`, which checks the
        // launcher on PATH, authorizes the wrapper and reapplies the mode.
        candidate.launchCommand = AgentLaunchCommand(
            arguments: ["claude", "--settings", "/tmp/subrouter-claude-settings-abc/settings.json", "--model", "opus"],
            environment: [
                SubrouterClaudeResumeRouting.environmentKey: "sr claude proxy --resume",
                SubrouterClaudeResumeRouting.launchBoundEnvironmentKey: "sr claude proxy --resume",
            ],
            launcherPrefix: prefix
        )
        #expect(candidate.routesThroughSubrouter)
        #expect(candidate.launcherResumeArguments(isReadableFile: { _ in true }) == nil)
    }

    @Test("launcher resume reapplies the observed permission mode unless the launch pinned one")
    func launcherResumeAppliesObservedPermissionMode() throws {
        let prefix = ["caffeinate", "-i", "claude"]
        var candidate = AgentRecoveryCandidate(
            kind: "claude",
            sessionId: "s1",
            workspaceId: nil,
            cwd: "/tmp",
            launchCommand: AgentLaunchCommand(arguments: ["claude", "--model", "opus"], launcherPrefix: prefix),
            permissionMode: "acceptEdits",
            lastActivity: now
        )
        let arguments = try #require(candidate.launcherResumeArguments(isReadableFile: { _ in true }))
        #expect(Array(arguments.prefix(5)) == prefix + ["--resume", "s1"])
        #expect(Array(arguments.suffix(2)) == ["--permission-mode", "acceptEdits"])

        candidate.launchCommand?.arguments = ["claude", "--dangerously-skip-permissions"]
        let pinned = try #require(candidate.launcherResumeArguments(isReadableFile: { _ in true }))
        #expect(!pinned.contains("--permission-mode"))

        // The planner carries the hook-observed mode onto the candidate.
        let planned = AgentSessionRecoveryPlanner().candidates(
            journal: [AgentRecoveryJournalSession(sessionId: "s1", source: "claude", lastOccurredAt: now, hasEnded: false)],
            records: [AgentRecoveryLaunchRecord(
                kind: "claude", sessionId: "s1", workspaceId: nil, cwd: "/tmp",
                launchCommand: nil, pid: nil, permissionMode: "plan", updatedAt: now
            )],
            openSessionIds: [],
            isProcessAlive: { _, _ in false },
            now: now
        )
        #expect(planned.first?.permissionMode == "plan")
    }

    @Test("launch commands without a launcher prefix still decode")
    func legacyLaunchCommandDecodes() throws {
        let data = Data(#"{"arguments":["claude"],"launcher":"claude"}"#.utf8)
        let command = try JSONDecoder().decode(AgentLaunchCommand.self, from: data)
        #expect(command.launcherPrefix == nil)
    }
}

/// A heavy user can have dozens of agents running when cmux dies; starting
/// them all on relaunch spikes CPU and memory. Only a few start at once.
@Suite("Agent session recovery start plan")
struct AgentRecoveryStartPlanTests {
    private let now = Date(timeIntervalSince1970: 1_790_428_300)

    private func candidate(
        _ id: String,
        minutesAgo: Double,
        workspaceId: UUID? = nil,
        launcherPrefix: [String]? = nil
    ) -> AgentRecoveryCandidate {
        AgentRecoveryCandidate(
            kind: "claude",
            sessionId: id,
            workspaceId: workspaceId?.uuidString,
            cwd: "/tmp",
            launchCommand: AgentLaunchCommand(arguments: ["claude"], launcherPrefix: launcherPrefix),
            lastActivity: now.addingTimeInterval(-minutesAgo * 60)
        )
    }

    @Test("the most recently active sessions start now and the rest wait for a visit")
    func startsMostRecentFirst() {
        let plan = AgentRecoveryStartPlan(
            candidates: (1...6).map { candidate("s\($0)", minutesAgo: Double(7 - $0)) },
            immediateLimit: 2
        )
        #expect(plan.startNow.map(\.sessionId) == ["s6", "s5"])
        #expect(plan.startOnVisit.map(\.sessionId) == ["s4", "s3", "s2", "s1"])
    }

    @Test("sessions from a workspace on screen start before more recent ones")
    func visibleWorkspacesStartFirst() {
        let visible = UUID()
        let plan = AgentRecoveryStartPlan(
            candidates: [
                candidate("recent", minutesAgo: 1),
                candidate("on-screen", minutesAgo: 30, workspaceId: visible),
                candidate("older", minutesAgo: 5),
            ],
            visibleWorkspaceIds: [visible],
            immediateLimit: 2
        )
        #expect(plan.startNow.map(\.sessionId) == ["on-screen", "recent"])
        #expect(plan.startOnVisit.map(\.sessionId) == ["older"])
    }

    /// A session resumed through its recorded launcher takes its launch claim
    /// when it is typed, and nothing would claim it on a later visit.
    @Test("a session resumed through its recorded launcher always starts now")
    func launcherSessionsStartNow() {
        let plan = AgentRecoveryStartPlan(
            candidates: [
                candidate("a", minutesAgo: 1),
                candidate("b", minutesAgo: 2),
                candidate("launcher", minutesAgo: 3, launcherPrefix: ["sr", "claude", "proxy", "--account", "me"]),
            ],
            immediateLimit: 1
        )
        #expect(plan.startNow.map(\.sessionId) == ["a", "launcher"])
        #expect(plan.startOnVisit.map(\.sessionId) == ["b"])
    }

    @Test("everything starts now when there are only a few sessions")
    func fewSessionsAllStartNow() {
        let plan = AgentRecoveryStartPlan(candidates: [candidate("a", minutesAgo: 1), candidate("b", minutesAgo: 2)])
        #expect(plan.startNow.map(\.sessionId) == ["a", "b"])
        #expect(plan.startOnVisit.isEmpty)
    }
}
