import AppKit
import Foundation

@MainActor
struct CmuxConfigExecutor {

    static func execute(
        command: CmuxCommandDefinition,
        tabManager: TabManager,
        baseCwd: String,
        configSourcePath: String?,
        globalConfigPath: String
    ) {
        if let workspace = command.workspace {
            executeWorkspaceCommand(command: command, workspace: workspace, tabManager: tabManager, baseCwd: baseCwd)
        } else if let shellCommand = command.command {
            let needsConfirm = command.confirm ?? false
            if needsConfirm, let sourcePath = configSourcePath {
                let trusted = CmuxDirectoryTrust.shared.isTrusted(
                    configPath: sourcePath,
                    globalConfigPath: globalConfigPath
                )
                if !trusted {
                    guard showConfirmDialog(command: shellCommand, configPath: sourcePath) else { return }
                }
            }
            guard let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return }
            terminal.sendInput(shellCommand + "\n")
        }
    }

    /// Show a confirmation dialog with the command text and a "trust this directory" checkbox.
    /// Returns true if the user chose to run, false if cancelled.
    private static func showConfirmDialog(command: String, configPath: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.cmuxConfig.confirmCommand.title",
            defaultValue: "Run Command"
        )
        let messageFormat = String(
            localized: "dialog.cmuxConfig.confirmCommand.messageWithCommand",
            defaultValue: "This will run the following command:\n\n%@"
        )
        alert.informativeText = String(format: messageFormat, sanitizeForDisplay(command))
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.run",
            defaultValue: "Run"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.cancel",
            defaultValue: "Cancel"
        ))

        let checkbox = NSButton(checkboxWithTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.trustDirectory",
            defaultValue: "Always trust commands from this folder"
        ), target: nil, action: nil)
        checkbox.state = .off
        alert.accessoryView = checkbox

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return false }

        if checkbox.state == .on {
            CmuxDirectoryTrust.shared.trust(configPath: configPath)
        }

        return true
    }

    private static func sanitizeForDisplay(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(text.unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
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
