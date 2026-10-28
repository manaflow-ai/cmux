import CMUXAgentLaunch
import Foundation

/// One workspace's session priority as cmux sees it now, for the socket and the CLI.
struct SessionPrioritySnapshot: Equatable, Sendable {
    /// One Claude pane of the workspace.
    struct Pane: Equatable, Sendable {
        var surfaceId: UUID
        var sessionId: String?
        /// The effort the pane's Claude was launched with, from its recorded launch environment.
        var currentEffort: ClaudeEffortLevel?
        var state: SessionPriorityPaneState
        /// How the pane's last restart attempt ended, e.g. `held.draft`; `nil` before any, and
        /// once the pane is left alone.
        var detail: String?
    }

    var workspaceId: UUID
    /// `nil` while session priority is off or the workspace has no Claude pane.
    var tier: SessionPriorityTier?
    var difficulty: ClaudeSessionDifficulty
    var difficultySource: SessionPriorityWorkspaceState.DifficultySource
    var difficultyOverride: ClaudeSessionDifficulty?
    var difficultyAuto: ClaudeSessionDifficulty?
    var isManual: Bool
    /// Why cmux leaves the workspace alone: the user's flag, else a pane's signal.
    var manualSignal: SessionPriorityManualSignal?
    /// What the workspace's tier and difficulty ask for; `nil` while off, while the workspace is
    /// marked manual, or while every Claude pane is left alone for its own signal. One pane's
    /// signal leaves the target in place: cmux still restarts the other panes to it.
    var target: SessionPriorityTarget?
    /// Empty while session priority is off.
    var panes: [Pane]

    /// Whether cmux adjusts this workspace's effort: it has a target, so it is not marked manual
    /// and not every Claude pane is left alone. The turn-end difficulty rating is skipped otherwise.
    var isAdjustable: Bool { target != nil }
}

extension SessionPrioritySnapshot {
    /// The snapshot of a workspace from what the coordinator read: its `priority` state, its
    /// plan `entry` (`nil` while off or outside the plan) and its Claude `panes` (none while
    /// off). The flag, or a signal on every pane, clears the target, so no arrow points at an
    /// effort cmux applies to none of the panes.
    @MainActor
    init(
        workspaceId: UUID,
        priority: SessionPriorityWorkspaceState,
        entry: SessionPriorityPlan.Entry?,
        panes: [Pane],
        enabled: Bool
    ) {
        let paneSignal = panes.lazy.compactMap { pane -> SessionPriorityManualSignal? in
            if case .manual(let signal) = pane.state { return signal }
            return nil
        }.first
        let manualSignal = enabled ? (priority.isManual ? .flag : paneSignal) : nil
        let appliesToNoPane = priority.isManual || SessionPriorityPaneState.allLeftAlone(panes.map(\.state))
        self.init(
            workspaceId: workspaceId,
            tier: entry?.tier,
            difficulty: priority.effectiveDifficulty,
            difficultySource: priority.difficultySource,
            difficultyOverride: priority.difficultyOverride,
            difficultyAuto: priority.autoDifficulty,
            isManual: priority.isManual,
            manualSignal: manualSignal,
            target: appliesToNoPane ? nil : entry?.target,
            panes: panes
        )
    }
}
