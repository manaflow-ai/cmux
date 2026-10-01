import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent recovery pane placement")
struct AgentRecoveryPanePlacementTests {
    private let workspace = UUID()
    private let panel = UUID()
    private let snapshotAt = Date(timeIntervalSince1970: 1_000)

    private func candidate(
        _ sessionId: String,
        at seconds: TimeInterval,
        surface: UUID? = nil,
        launchCommand: AgentLaunchCommand? = nil
    ) -> AgentRecoveryCandidate {
        AgentRecoveryCandidate(
            kind: "claude",
            sessionId: sessionId,
            workspaceId: workspace.uuidString,
            surfaceId: (surface ?? panel).uuidString,
            cwd: "/tmp",
            launchCommand: launchCommand,
            lastActivity: Date(timeIntervalSince1970: seconds)
        )
    }

    private func pane(sessionId: String? = nil, canHostAgent: Bool = true) -> AgentRecoveryPane {
        AgentRecoveryPane(workspaceId: workspace, panelId: panel, sessionId: sessionId, canHostAgent: canHostAgent)
    }

    private var key: AgentRecoveryPanePlacement.PanelKey { .init(workspaceId: workspace, panelId: panel) }

    @Test("an agent started after the last autosave returns to its own panel")
    func emptyPanelTakesSession() {
        let placement = AgentRecoveryPanePlacement(
            candidates: [candidate("new", at: 1_005)], panes: [pane()], snapshotCreatedAt: snapshotAt
        )
        #expect(placement.assignments[key]?.sessionId == "new")
    }

    @Test("a newer session replaces the stale one the snapshot bound")
    func newerSessionReplacesStaleBinding() {
        let placement = AgentRecoveryPanePlacement(
            candidates: [candidate("new", at: 1_005)], panes: [pane(sessionId: "old")], snapshotCreatedAt: snapshotAt
        )
        #expect(placement.assignments[key]?.sessionId == "new")
    }

    @Test("evidence older than the snapshot never overrides its binding")
    func olderEvidenceKeepsSnapshot() {
        let placement = AgentRecoveryPanePlacement(
            candidates: [candidate("other", at: 990)], panes: [pane(sessionId: "old")], snapshotCreatedAt: snapshotAt
        )
        #expect(placement.assignments.isEmpty)
    }

    @Test("tmux, remote and cloud panels are left alone")
    func nonLocalPanelsSkipped() {
        let placement = AgentRecoveryPanePlacement(
            candidates: [candidate("new", at: 1_005)], panes: [pane(canHostAgent: false)], snapshotCreatedAt: snapshotAt
        )
        #expect(placement.assignments.isEmpty)
    }

    @Test("a session whose panel is gone is not placed")
    func missingPanelSkipped() {
        let placement = AgentRecoveryPanePlacement(
            candidates: [candidate("new", at: 1_005, surface: UUID())], panes: [pane()], snapshotCreatedAt: snapshotAt
        )
        #expect(placement.assignments.isEmpty)
    }

    @Test("two sessions recorded for one panel resume the most recent")
    func mostRecentWins() {
        let placement = AgentRecoveryPanePlacement(
            candidates: [candidate("a", at: 1_002), candidate("b", at: 1_009), candidate("c", at: 1_004)],
            panes: [pane()],
            snapshotCreatedAt: snapshotAt
        )
        #expect(placement.assignments[key]?.sessionId == "b")
    }

    @Test("a session resumed through its recorded launcher keeps the new-workspace path")
    func launcherResumeSkipped() {
        let launch = AgentLaunchCommand(arguments: ["claude"], launcherPrefix: ["sr", "claude", "proxy", "--account", "me@example.com"])
        let routed = candidate("new", at: 1_005, launchCommand: launch)
        #expect(routed.launcherResumeArguments != nil)
        let placement = AgentRecoveryPanePlacement(candidates: [routed], panes: [pane()], snapshotCreatedAt: snapshotAt)
        #expect(placement.assignments.isEmpty)
    }

    @Test("the planner carries the hook-recorded panel into each candidate")
    func plannerCarriesSurface() {
        let now = Date(timeIntervalSince1970: 2_000)
        let candidates = AgentSessionRecoveryPlanner().candidates(
            journal: [AgentRecoveryJournalSession(sessionId: "s1", source: "claude", lastOccurredAt: now, hasEnded: false)],
            records: [AgentRecoveryLaunchRecord(
                kind: "claude", sessionId: "s1", workspaceId: workspace.uuidString, surfaceId: panel.uuidString,
                cwd: "/tmp", launchCommand: nil, pid: nil, updatedAt: now
            )],
            openSessionIds: [],
            isProcessAlive: { _, _ in false },
            now: now
        )
        #expect(candidates.map(\.surfaceId) == [panel.uuidString])
    }
}
