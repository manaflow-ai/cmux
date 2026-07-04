enum SessionSnapshotRepairer {
    static func repair(_ snapshot: AppSessionSnapshot) -> (snapshot: AppSessionSnapshot, didRepair: Bool) {
        var didRepair = false
        var repaired = snapshot
        repaired.windows = repaired.windows.map { window in
            repair(window, didRepair: &didRepair)
        }
        return (snapshot: repaired, didRepair: didRepair)
    }

    private static func repair(
        _ window: SessionWindowSnapshot,
        didRepair: inout Bool
    ) -> SessionWindowSnapshot {
        var repaired = window
        repaired.tabManager.workspaces = repaired.tabManager.workspaces.map { workspace in
            repair(workspace, didRepair: &didRepair)
        }
        return repaired
    }

    private static func repair(
        _ workspace: SessionWorkspaceSnapshot,
        didRepair: inout Bool
    ) -> SessionWorkspaceSnapshot {
        var repaired = workspace
        repaired.panels = repaired.panels.map { panel in
            repair(panel, workspaceDirectory: workspace.currentDirectory, didRepair: &didRepair)
        }
        return repaired
    }

    private static func repair(
        _ panel: SessionPanelSnapshot,
        workspaceDirectory: String,
        didRepair: inout Bool
    ) -> SessionPanelSnapshot {
        guard var terminal = panel.terminal else { return panel }
        let fallbackWorkingDirectory = firstNormalizedDirectory(
            terminal.workingDirectory,
            panel.directory,
            workspaceDirectory
        )

        if let resumeBinding = terminal.resumeBinding {
            let trustedBinding = resumeBinding.trustedForSessionRestore
            if trustedBinding == nil {
                didRepair = true
            }
            terminal.resumeBinding = trustedBinding
        }

        if let agent = terminal.agent {
            let repairedAgent = agent.repairedForSessionRestore(
                fallbackWorkingDirectory: fallbackWorkingDirectory
            )
            if agent.launchCommand != repairedAgent.launchCommand
                || agent.workingDirectory != repairedAgent.workingDirectory {
                didRepair = true
            }
            terminal.agent = repairedAgent
        }

        var repaired = panel
        repaired.terminal = terminal
        return repaired
    }

    private static func firstNormalizedDirectory(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let normalized = SurfaceResumeCommandCanonicalizer.normalizedCWD(candidate) {
                return normalized
            }
        }
        return nil
    }
}
