import AppKit
import Foundation

@MainActor
struct CmuxConfigExecutor {

    static func execute(
        command: CmuxCommandDefinition,
        tabManager: TabManager,
        baseCwd: String
    ) {
        if let workspace = command.workspace {
            executeWorkspaceCommand(command: command, workspace: workspace, tabManager: tabManager, baseCwd: baseCwd)
        } else if let shellCommand = command.command {
            executeSimpleCommand(shellCommand, confirm: command.confirm ?? false, tabManager: tabManager)
        }
    }

    private static func executeSimpleCommand(
        _ command: String,
        confirm: Bool,
        tabManager: TabManager
    ) {
        if confirm {
            let alert = NSAlert()
            alert.messageText = String(localized: "dialog.cmuxConfig.confirmCommand.title", defaultValue: "Run Command")
            alert.informativeText = String(
                localized: "dialog.cmuxConfig.confirmCommand.message",
                defaultValue: "Are you sure you want to run this command?"
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "dialog.cmuxConfig.confirmCommand.run", defaultValue: "Run"))
            alert.addButton(withTitle: String(localized: "dialog.cmuxConfig.confirmCommand.cancel", defaultValue: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        guard let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return }
        terminal.sendInput(command + "\n")
    }

    private static func executeWorkspaceCommand(
        command: CmuxCommandDefinition,
        workspace wsDef: CmuxWorkspaceDefinition,
        tabManager: TabManager,
        baseCwd: String
    ) {
        let workspaceName = wsDef.name ?? command.name
        let restart = command.restart ?? .ignore

        if let existing = tabManager.tabs.first(where: { $0.customTitle == workspaceName }) {
            switch restart {
            case .ignore:
                tabManager.selectWorkspace(existing)
                return
            case .recreate:
                tabManager.closeWorkspace(existing)
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
                alert.addButton(withTitle: String(localized: "dialog.cmuxConfig.confirmRestart.recreate", defaultValue: "Recreate"))
                alert.addButton(withTitle: String(localized: "dialog.cmuxConfig.confirmRestart.cancel", defaultValue: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else {
                    tabManager.selectWorkspace(existing)
                    return
                }
                tabManager.closeWorkspace(existing)
            }
        }

        let resolvedCwd = CmuxConfigStore.resolveCwd(wsDef.cwd, relativeTo: baseCwd)
        let newWorkspace = tabManager.addWorkspace(workingDirectory: resolvedCwd)
        newWorkspace.setCustomTitle(workspaceName)
        if let color = wsDef.color {
            newWorkspace.setCustomColor(color)
        }

        guard let layout = wsDef.layout else { return }
        newWorkspace.applyCustomLayout(layout, baseCwd: resolvedCwd)
    }
}
