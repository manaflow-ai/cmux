import AppKit
import CmuxTerminal
import CmuxWorkspaces
import Foundation

extension AppDelegate {
    /// Live terminals a scrollback checkpoint may capture: the same panels the
    /// session snapshot walks (registered windows, their docks, and windowless
    /// routes that still fit the persisted window budget).
    func sessionScrollbackCheckpointCandidates() -> [SessionScrollbackCheckpointCoordinator.Candidate] {
        var candidates: [SessionScrollbackCheckpointCoordinator.Candidate] = []
        var seen = Set<UUID>()
        let restorePolicy = Workspace.makeSessionRestorePolicyService()

        func append(
            panelId: UUID,
            terminal: TerminalPanel,
            shellActivityState: PanelShellActivityState?
        ) {
            guard seen.insert(panelId).inserted else { return }
            // Mirrors the snapshot gates: a running command or a hibernated
            // agent does not persist scrollback (see `sessionPanelSnapshot`).
            // `snapshotNeedsConfirmClose` is the lock-free variant (#6381).
            let closeConfirmationRequired = Workspace.resolveCloseConfirmation(
                shellActivityState: shellActivityState,
                fallbackNeedsConfirmClose: terminal.surface.snapshotNeedsConfirmClose()
            )
            let isEligible = restorePolicy
                .shouldPersistSessionScrollback(closeConfirmationRequired: closeConfirmationRequired)
                && terminal.agentHibernationState == nil
            candidates.append(SessionScrollbackCheckpointCoordinator.Candidate(
                panelId: panelId,
                surfaceId: terminal.surface.id,
                isEligible: isEligible,
                capture: { [weak terminal] in
                    guard let terminal else { return nil }
                    // Same capture the quit path uses for each terminal.
                    return TerminalController.shared.readTerminalTextForSnapshot(
                        terminalPanel: terminal,
                        includeScrollback: true,
                        lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                    )
                }
            ))
        }
        func appendTerminals(from dock: DockSplitStore) {
            for (panelId, panel) in dock.panels {
                guard let terminal = panel as? TerminalPanel else { continue }
                append(panelId: panelId, terminal: terminal, shellActivityState: terminal.shellActivity.state)
            }
        }
        func appendTerminals(from manager: TabManager) {
            for workspace in manager.tabs {
                let shellActivityStates = workspace.panelShellActivityStates
                for (panelId, panel) in workspace.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    append(panelId: panelId, terminal: terminal, shellActivityState: shellActivityStates[panelId])
                }
                if let dock = workspace._dockSplit {
                    appendTerminals(from: dock)
                }
            }
        }

        for context in mainWindowContexts.values {
            appendTerminals(from: context.tabManager)
            if let dock = context.existingWindowDock() {
                appendTerminals(from: dock)
            }
        }
        for route in mainWindowLifecycleCoordinator.eligibleOrphanedRoutesForPersistence() {
            guard let manager = route.tabManager else { continue }
            appendTerminals(from: manager)
            if case .live(let dock)? = route.windowDock {
                appendTerminals(from: dock)
            }
        }
        return candidates
    }
}
