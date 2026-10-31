import CMUXAgentLaunch
import CmuxControlSocket
import CmuxSettings
import Foundation

/// The session-priority witnesses for ``ControlCommandCoordinator``: resolves
/// the target workspace like the workspace-todo domain, reads it through
/// `SessionPriorityCoordinator`, and mutates it only through the
/// `Workspace+SessionPriority` entry points. Values cross the seam as wire
/// strings. These methods are relay-denied (not in `RemoteRelayCommandPolicy`).
extension TerminalController: ControlSessionPriorityContext {
    // MARK: - Snapshots

    private func sessionPriorityWire(_ snapshot: SessionPrioritySnapshot) -> ControlSessionPrioritySnapshot {
        ControlSessionPrioritySnapshot(
            workspaceId: snapshot.workspaceId,
            enabled: SessionPriorityCoordinator.shared.isEnabled,
            tier: snapshot.tier?.rawValue,
            difficulty: snapshot.difficulty.rawValue,
            difficultySource: snapshot.difficultySource.rawValue,
            difficultyOverride: snapshot.difficultyOverride?.rawValue,
            difficultyAuto: snapshot.difficultyAuto?.rawValue,
            manual: snapshot.isManual,
            manualSignal: snapshot.manualSignal?.rawValue,
            targetEffort: snapshot.target?.effort?.rawValue,
            targetModel: snapshot.target?.model,
            panes: snapshot.panes.map { pane in
                let (state, stateDetail) = Self.sessionPriorityWireState(pane.state)
                return ControlSessionPrioritySnapshot.Pane(
                    surfaceId: pane.surfaceId,
                    sessionId: pane.sessionId,
                    currentEffort: pane.currentEffort?.rawValue,
                    state: state,
                    detail: pane.detail ?? stateDetail
                )
            }
        )
    }

    private static func sessionPriorityWireState(_ state: SessionPriorityPaneState) -> (String, String?) {
        switch state {
        case .upToDate: return ("up_to_date", nil)
        case .applying: return ("applying", nil)
        case .held(let reason): return ("held", "held.\(reason.rawValue)")
        case .notApplied(let refusal): return ("not_applied", refusal.map { "refused.\($0.rawValue)" })
        case .manual(let signal): return ("manual", signal.rawValue)
        }
    }

    private func sessionPriorityResolved(
        tabManager: TabManager,
        workspace: Workspace
    ) -> ControlSessionPriorityResolution {
        .resolved(
            windowID: AppDelegate.shared?.windowId(for: tabManager),
            snapshot: sessionPriorityWire(SessionPriorityCoordinator.shared.snapshot(for: workspace))
        )
    }

    // MARK: - Witnesses

    func controlSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlSessionPriorityResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable: return .tabManagerUnavailable
        case .notFound: return .notFound
        case .found(let tabManager, let workspace):
            return sessionPriorityResolved(tabManager: tabManager, workspace: workspace)
        }
    }

    func controlSetSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        difficultyRaw: String?,
        clearDifficulty: Bool,
        manual: Bool?,
        source: String
    ) -> ControlSessionPriorityResolution {
        switch resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) {
        case .tabManagerUnavailable: return .tabManagerUnavailable
        case .notFound: return .notFound
        case .found(let tabManager, let workspace):
            var difficulty: ClaudeSessionDifficulty?
            if let difficultyRaw {
                // Validate before mutating anything so a bad value changes nothing.
                guard let parsed = ClaudeSessionDifficulty(rawValue: difficultyRaw) else {
                    return .invalidDifficulty(difficultyRaw)
                }
                difficulty = parsed
            }
            if source == "auto" {
                if let difficulty { workspace.setAutoClaudeDifficulty(difficulty) }
            } else {
                if clearDifficulty {
                    workspace.setClaudeDifficultyOverride(nil)
                } else if let difficulty {
                    workspace.setClaudeDifficultyOverride(difficulty)
                }
                if let manual { workspace.setSessionPriorityManual(manual) }
            }
            return sessionPriorityResolved(tabManager: tabManager, workspace: workspace)
        }
    }

    func controlProbeSessionPriority(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlSessionPriorityProbe? {
        guard case .found(_, let workspace) = resolveTodoWorkspace(routing: routing, workspaceID: workspaceID) else {
            return nil
        }
        return ControlSessionPriorityProbe(
            enabled: AutomationCatalogSection().sessionPriority.value(in: .standard),
            workspaceId: workspace.id,
            manual: workspace.sessionPriorityState.isManual,
            overridePresent: workspace.sessionPriorityState.difficultyOverride != nil
        )
    }

    func controlSessionPriorityStatus(
        routing: ControlRoutingSelectors
    ) -> ControlSessionPriorityStatusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else { return .tabManagerUnavailable }
        let section = AutomationCatalogSection()
        return .resolved(
            windowID: AppDelegate.shared?.windowId(for: tabManager),
            enabled: section.sessionPriority.value(in: .standard),
            urgentCount: section.sessionPriorityUrgentCount.value(in: .standard),
            workspaces: SessionPriorityCoordinator.shared.statusSnapshot(tabManager: tabManager)
                .map(sessionPriorityWire)
        )
    }
}
