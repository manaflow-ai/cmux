import AppKit
import Foundation

/// Resumes a Vault `SessionEntry` into a terminal surface. Owns a
/// constructor-injected `TabManager` and reuses the focused pane when its
/// working directory already matches the entry's resume cwd; otherwise it
/// opens a fresh workspace seeded with the resume command.
///
/// Constructed at the Sessions-sidebar composition point
/// (`RightSidebarToolPanelView`) and invoked as `resume(entry)`. Stays
/// app-side because it reaches app-only `TabManager`/`Workspace` state
/// (`selectedWorkspace`, `selectedTabId`, `tabs`, `addWorkspace`,
/// `currentDirectory`, `bonsplitController.focusedPaneId`,
/// `newTerminalSurface`).
@MainActor
struct SessionResumeCoordinator {
    private let tabManager: TabManager

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func resume(_ entry: SessionEntry) {
        guard let resumeCommand = entry.resumeCommandWithCwd else { return }
        let inputWithReturn = resumeCommand + "\n"
        let targetCwd = entry.resumeWorkingDirectory

        let selected = tabManager.selectedWorkspace
        let selectedTab = tabManager.selectedTabId.flatMap { id in
            tabManager.tabs.first(where: { $0.id == id })
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

        tabManager.addWorkspace(
            workingDirectory: targetCwd,
            initialTerminalInput: inputWithReturn
        )
    }
}
