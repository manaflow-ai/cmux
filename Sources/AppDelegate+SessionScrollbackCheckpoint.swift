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
                beginCapture: { [weak terminal] in
                    guard let terminal else { return nil }
                    return TerminalScrollbackCheckpointExport.begin(
                        terminal: terminal,
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

    /// Restored scrollback held in memory for live terminal panels, keyed by
    /// their current (post-restore) panel ids.
    func sessionScrollbackCheckpointRestoredSeeds() -> [SessionScrollbackCheckpointCoordinator.Seed] {
        var seeds: [SessionScrollbackCheckpointCoordinator.Seed] = []
        var seen = Set<UUID>()
        func append(_ scrollbackByPanelId: [UUID: String], panels: [UUID: any Panel]) {
            for (panelId, scrollback) in scrollbackByPanelId {
                guard let terminal = panels[panelId] as? TerminalPanel,
                      seen.insert(panelId).inserted else { continue }
                seeds.append(.init(panelId: panelId, surfaceId: terminal.surface.id, scrollback: scrollback))
            }
        }
        func append(from dock: DockSplitStore) {
            append(dock.restoredTerminalScrollbackByPanelId, panels: dock.panels)
        }
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                append(workspace.restoredTerminalScrollbackByPanelId, panels: workspace.panels)
                if let dock = workspace._dockSplit {
                    append(from: dock)
                }
            }
            if let dock = context.existingWindowDock() {
                append(from: dock)
            }
        }
        return seeds
    }
}

/// Splits the quit path's VT-export capture so only the Ghostty call runs on main.
enum TerminalScrollbackCheckpointExport {
    /// Main-thread half: Ghostty formats the terminal's scrollback into a temp
    /// file. Returns the off-main reader, or nil when the export failed.
    @MainActor
    static func begin(terminal: TerminalPanel, lineLimit: Int) -> (@Sendable () -> String?)? {
        let exportedPath = GhosttyApp.terminalPasteboard.captureNextStandardClipboardWrite {
            terminal.performInternalBindingAction("write_screen_file:copy,vt")
        }
        guard let path = TerminalController.normalizedExportedScreenPath(exportedPath) else { return nil }
        let fileURL = URL(fileURLWithPath: path)
        return { TerminalScrollbackCheckpointExport.read(fileURL: fileURL, lineLimit: lineLimit) }
    }

    /// Off-main half; mirrors `readTerminalTextFromVTExportForSnapshot` after the export.
    nonisolated static func read(fileURL: URL, lineLimit: Int) -> String? {
        defer {
            if TerminalController.shouldRemoveExportedScreenFile(fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                if TerminalController.shouldRemoveExportedScreenDirectory(fileURL: fileURL) {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
            }
        }
        guard let data = try? Data(contentsOf: fileURL),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return TerminalController.tailTerminalLines(
            TerminalController.normalizedMobileVTExportText(raw),
            maxLines: lineLimit
        )
    }
}
