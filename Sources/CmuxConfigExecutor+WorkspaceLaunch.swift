import AppKit
import Foundation

// MARK: - Workspace command launch (named and inline `type: "workspace"` actions)

extension CmuxConfigExecutor {

    static func executeWorkspaceCommand(
        command: CmuxCommandDefinition,
        workspace wsDef: CmuxWorkspaceDefinition,
        tabManager: TabManager,
        baseCwd: String
    ) -> Bool {
        let workspaceName = wsDef.name ?? command.name
        let restart = command.restart ?? .new
        var existingWorkspaceToClose: Workspace?

        if let existing = tabManager.tabs.first(where: { $0.customTitle == workspaceName }) {
            switch restart {
            case .new:
                break
            case .ignore:
                tabManager.selectWorkspace(existing)
                return true
            case .recreate:
                existingWorkspaceToClose = existing
            case .confirm:
                let alert = NSAlert()
                alert.messageText = String(
                    localized: "dialog.cmuxConfig.confirmRestart.title",
                    defaultValue: "Workspace Already Exists"
                )
                alert.informativeText = String(
                    localized: "dialog.cmuxConfig.confirmRestart.message",
                    defaultValue: "A workspace with this name already exists. Close it and create a new one?"
                )
                alert.alertStyle = .warning
                alert.addButton(withTitle: String(
                    localized: "dialog.cmuxConfig.confirmRestart.recreate",
                    defaultValue: "Recreate"
                ))
                alert.addButton(withTitle: String(
                    localized: "dialog.cmuxConfig.confirmRestart.cancel",
                    defaultValue: "Cancel"
                ))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    tabManager.selectWorkspace(existing)
                    return false
                }
                existingWorkspaceToClose = existing
            }
        }

        let resolvedCwd = CmuxConfigStore.resolveCwd(wsDef.cwd, relativeTo: baseCwd)
        let newWorkspace = tabManager.addWorkspace(
            workingDirectory: resolvedCwd,
            workspaceEnvironment: wsDef.env ?? [:]
        )
        newWorkspace.setCustomTitle(workspaceName)
        if let color = wsDef.color {
            newWorkspace.setCustomColor(color)
        }

        if let existingWorkspaceToClose, existingWorkspaceToClose.id != newWorkspace.id {
            tabManager.closeWorkspace(existingWorkspaceToClose)
        }

        if let layout = wsDef.layout {
            newWorkspace.applyCustomLayout(layout, baseCwd: resolvedCwd, setupCommand: wsDef.setup)
        } else if let setup = wsDef.setup {
            newWorkspace.sendConfigSetupCommand(setup)
        }
        return true
    }
}
