import AppKit
import Bonsplit
import Foundation

extension TabManager {
    /// Resume a vault session entry into this window's tabs. If the currently
    /// selected (non-remote) workspace already sits in the entry's working
    /// directory, opens a new terminal surface in its focused pane and replays
    /// the resume command there; otherwise opens a fresh workspace seeded with
    /// the resume command.
    func resume(_ entry: SessionEntry) {
        guard let resumeCommand = entry.resumeCommandWithCwd else { return }
        let inputWithReturn = resumeCommand + "\n"
        let targetCwd = entry.resumeWorkingDirectory

        let selected = selectedWorkspace
        let selectedTab = selectedTabId.flatMap { id in
            tabs.first(where: { $0.id == id })
        }
        let isRemoteSelection = selectedTab?.isRemoteWorkspace ?? false
        let workspaceCwd = selected?.currentDirectory
        let pwdMatches: Bool = {
            guard !isRemoteSelection,
                  let targetCwd, !targetCwd.isEmpty,
                  let workspaceCwd, !workspaceCwd.isEmpty else { return false }
            let lhs = (targetCwd as NSString).standardizingPath
            let rhs = (workspaceCwd as NSString).standardizingPath
            return lhs == rhs
        }()

        if pwdMatches,
           let workspace = selected,
           let paneId = workspace.bonsplitController.focusedPaneId {
            workspace.newTerminalSurface(
                inPane: paneId,
                focus: true,
                workingDirectory: targetCwd,
                initialInput: inputWithReturn
            )
            return
        }

        addWorkspace(
            workingDirectory: targetCwd,
            initialTerminalInput: inputWithReturn
        )
    }
}
