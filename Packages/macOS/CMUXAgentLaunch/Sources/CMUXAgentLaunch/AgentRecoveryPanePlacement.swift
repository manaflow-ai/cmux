import Foundation

/// A terminal panel in the snapshot a crashed run left behind.
public struct AgentRecoveryPane: Equatable, Sendable {
    public var workspaceId: UUID
    public var panelId: UUID
    /// The agent session the snapshot already binds to this panel, if any.
    public var sessionId: String?
    /// False for panels whose restore is owned by something other than a
    /// local shell (tmux attach, remote or cloud terminal).
    public var canHostAgent: Bool

    public init(workspaceId: UUID, panelId: UUID, sessionId: String?, canHostAgent: Bool) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.sessionId = sessionId
        self.canHostAgent = canHostAgent
    }
}

/// Puts recovered agent sessions back into the panels they ran in.
///
/// The session snapshot is written every few seconds, so after a crash it can
/// predate the newest agent in a panel. The hook store records the panel each
/// session ran in the moment it starts, and the journal records whether it
/// ended. Folding those into the snapshot before restore lets startup restore
/// resume the session in its original panel; only sessions whose panel is gone
/// fall back to a new workspace.
///
/// A panel takes a candidate when it is a local shell and either binds no
/// session or the candidate was active after the snapshot was written, since a
/// panel runs one foreground agent and the newer evidence wins. Candidates that
/// resume through a recorded launcher keep the new-workspace path, which owns
/// that launch.
public struct AgentRecoveryPanePlacement: Equatable, Sendable {
    public struct PanelKey: Hashable, Sendable {
        public var workspaceId: UUID
        public var panelId: UUID

        public init(workspaceId: UUID, panelId: UUID) {
            self.workspaceId = workspaceId
            self.panelId = panelId
        }
    }

    /// The session each panel resumes.
    public private(set) var assignments: [PanelKey: AgentRecoveryCandidate] = [:]

    /// - Parameters:
    ///   - candidates: Sessions the journal saw running when the app died.
    ///   - panes: Terminal panels in the snapshot.
    ///   - snapshotCreatedAt: When the snapshot was written.
    public init(
        candidates: [AgentRecoveryCandidate],
        panes: [AgentRecoveryPane],
        snapshotCreatedAt: Date
    ) {
        var panesByKey: [PanelKey: AgentRecoveryPane] = [:]
        for pane in panes {
            panesByKey[PanelKey(workspaceId: pane.workspaceId, panelId: pane.panelId)] = pane
        }
        for candidate in candidates {
            guard candidate.launcherResumeArguments == nil,
                  let workspaceId = candidate.workspaceId.flatMap(UUID.init(uuidString:)),
                  let panelId = candidate.surfaceId.flatMap(UUID.init(uuidString:)) else { continue }
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard let pane = panesByKey[key], pane.canHostAgent else { continue }
            if let boundSessionId = pane.sessionId {
                guard boundSessionId != candidate.sessionId,
                      candidate.lastActivity > snapshotCreatedAt else { continue }
            }
            if let existing = assignments[key], existing.lastActivity >= candidate.lastActivity { continue }
            assignments[key] = candidate
        }
    }
}
