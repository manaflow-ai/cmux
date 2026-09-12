import Bonsplit
import Foundation

/// Executes a Vault row drop through the same restore plan used by row resume.
///
/// A remote-tmux mirror has no cmux relay socket, so it cannot resolve a local
/// restore record. Such a drop is redirected to the selected local workspace
/// instead of creating a remote tab whose startup input would be discarded.
@MainActor
struct VaultSessionDropLauncher {
    /// Places one Vault entry in `workspace` or redirects a projected mirror
    /// drop to a local restore workspace.
    @discardableResult
    func launch(
        entry: SessionEntry,
        in workspace: Workspace,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        guard let launch = entry.resumeLaunch else { return false }
        if workspace.isRemoteTmuxMirror {
            guard let tabManager = workspace.owningTabManager else { return false }
            return SessionEntryResumeCoordinator().resume(entry, tabManager: tabManager)
        }

        let remoteStartupCommand = workspace.isRemoteWorkspace
            ? workspace.effectiveRemoteTerminalStartupCommand(from: workspace.remoteConfiguration)
            : nil
        guard !workspace.isRemoteWorkspace || remoteStartupCommand != nil else {
            return false
        }
        let isRemoteHost = remoteStartupCommand != nil
        let dialect: TerminalStartupShellDialect = isRemoteHost ? .remoteHost : .loginShell
        let initialInput = launch.startupInput(for: dialect)
        let workingDirectory = isRemoteHost ? nil : launch.workingDirectory

        switch destination {
        case .insert(let paneId, let targetIndex):
            guard let panel = workspace.newTerminalSurface(
                inPane: paneId,
                focus: true,
                workingDirectory: workingDirectory,
                initialInput: initialInput,
                startupRestoreAgent: launch.startupRestoreAgent
            ) else {
                return false
            }
            // `newTerminalSurface` inserts according to the pane's default
            // policy. A drag request may carry an explicit tab index, so apply
            // that placement after the panel has an authoritative surface id.
            if let targetIndex {
                _ = workspace.reorderSurface(
                    panelId: panel.id,
                    toIndex: targetIndex,
                    focus: true
                )
            }
            if remoteStartupCommand != nil,
               let launchWorkingDirectory = launch.workingDirectory {
                workspace.updateVaultRemotePanelDirectory(
                    panelId: panel.id,
                    directory: launchWorkingDirectory
                )
            }
            return true
        case .split(let paneId, let orientation, let insertFirst):
            guard let panel = workspace.splitPaneWithNewTerminal(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                workingDirectory: workingDirectory,
                initialInput: initialInput,
                startupRestoreAgent: launch.startupRestoreAgent,
                remoteStartupCommand: remoteStartupCommand
            ) else {
                return false
            }
            if remoteStartupCommand != nil,
               let launchWorkingDirectory = launch.workingDirectory {
                workspace.updateVaultRemotePanelDirectory(
                    panelId: panel.id,
                    directory: launchWorkingDirectory
                )
            }
            return true
        }
    }
}

private extension Workspace {
    /// Seeds saved Vault cwd metadata without claiming it came from the remote host.
    @discardableResult
    func updateVaultRemotePanelDirectory(panelId: UUID, directory: String) -> Bool {
        updatePanelDirectory(
            panelId: panelId,
            directory: directory,
            displayLabel: nil,
            source: .restoredSnapshotMetadata
        )
    }
}
