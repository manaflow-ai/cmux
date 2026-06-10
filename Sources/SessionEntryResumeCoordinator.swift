import AppKit
import Bonsplit
import CMUXAgentVault
import SQLite3
import SwiftUI
import UniformTypeIdentifiers


@MainActor
enum SessionEntryResumeCoordinator {
    static func resume(_ entry: SessionEntry, tabManager: TabManager) {
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

