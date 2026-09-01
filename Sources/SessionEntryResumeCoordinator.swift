import Foundation

/// Owns placement for every interactive Vault resume request.
///
/// The launch value is prepared before placement, and the same snapshot is
/// passed to the terminal topology owner that receives the startup input. A
/// remote SSH or remote-tmux selection never receives a local Vault terminal;
/// it gets an isolated local workspace instead, where the restore record and
/// `cmux restore` selector share one owner.
@MainActor
enum SessionEntryResumeCoordinator {
    /// Resumes `entry`, preserving the historical same-cwd split behavior for
    /// local workspaces and the new-workspace behavior for every other target.
    ///
    /// - Returns: `true` when a terminal/workspace was created, otherwise `false`.
    @discardableResult
    static func resume(_ entry: SessionEntry, tabManager: TabManager) -> Bool {
        guard let launch = entry.resumeLaunch else { return false }
        let targetCwd = launch.workingDirectory
        let selected = tabManager.selectedWorkspace
        let isRemoteSelection = selected?.isRemoteWorkspace == true
            || selected?.isRemoteTmuxMirror == true
        let workspaceCwd = selected?.currentDirectory
        let pwdMatches: Bool = {
            guard !isRemoteSelection,
                  let targetCwd, !targetCwd.isEmpty,
                  let workspaceCwd, !workspaceCwd.isEmpty else { return false }
            let lhs = (targetCwd as NSString).standardizingPath
            let rhs = (workspaceCwd as NSString).standardizingPath
            return lhs == rhs
        }()
        let startupInput = launch.startupInput(for: .loginShell)

        if pwdMatches,
           let workspace = selected,
           let paneId = workspace.bonsplitController.focusedPaneId,
           workspace.newTerminalSurface(
               inPane: paneId,
               focus: true,
               workingDirectory: targetCwd,
               initialInput: startupInput,
               startupRestoreAgent: launch.startupRestoreAgent
           ) != nil {
            return true
        }

        return tabManager.addWorkspaceIfActive(
            workingDirectory: targetCwd,
            initialTerminalInput: startupInput,
            initialTerminalStartupRestoreAgent: launch.startupRestoreAgent
        ) != nil
    }
}
