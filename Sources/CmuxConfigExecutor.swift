import AppKit
import Foundation

@MainActor
struct CmuxConfigExecutor {
    enum PreparedShellCommand: Equatable {
        case ready(String, repoRoot: String?)
        case missingRepoRoot(String)
    }

    fileprivate static var confirmCommandAlertFactory: () -> NSAlert = { NSAlert() }
    fileprivate static var repoRootFallbackAlertFactory: () -> NSAlert = { NSAlert() }
    fileprivate static var commandSender: (TerminalPanel, String) -> Void = { terminal, text in
        terminal.sendInput(text)
    }

    static func execute(
        command: CmuxCommandDefinition,
        tabManager: TabManager,
        baseCwd: String,
        configSourcePath: String?,
        globalConfigPath: String
    ) {
        if let workspace = command.workspace {
            executeWorkspaceCommand(command: command, workspace: workspace, tabManager: tabManager, baseCwd: baseCwd)
        } else if let rawCommand = command.command {
            let displayCommand = sanitizeForDisplay(rawCommand)
            let preparedCommand = prepareShellCommand(
                displayCommand,
                baseCwd: baseCwd,
                requiresRepoRoot: command.repoRoot ?? false
            )
            let shellCommand: String
            let repoRoot: String?
            switch preparedCommand {
            case .ready(let preparedShell, let resolvedRepoRoot):
                shellCommand = preparedShell
                repoRoot = resolvedRepoRoot
            case .missingRepoRoot(let fallbackShell):
                guard showRepoRootFallbackDialog() else { return }
                shellCommand = fallbackShell
                repoRoot = nil
            }
            let needsConfirm = command.confirm ?? false
            if needsConfirm, let sourcePath = configSourcePath {
                let trusted = CmuxDirectoryTrust.shared.isTrusted(
                    configPath: sourcePath,
                    globalConfigPath: globalConfigPath
                )
                if !trusted {
                    guard showConfirmDialog(command: displayCommand, configPath: sourcePath, repoRoot: repoRoot) else { return }
                }
            }
            guard let terminal = tabManager.selectedWorkspace?.focusedTerminalPanel else { return }
            commandSender(terminal, shellCommand + "\n")
        }
    }

    static func prepareShellCommand(
        _ command: String,
        baseCwd: String,
        requiresRepoRoot: Bool
    ) -> PreparedShellCommand {
        guard requiresRepoRoot else {
            return .ready(command, repoRoot: nil)
        }
        guard let repoRoot = CmuxConfigStore.findGitRoot(from: baseCwd) else {
            return .missingRepoRoot(command)
        }
        return .ready("(cd \(shellQuote(repoRoot)) && \(command))", repoRoot: repoRoot)
    }

    /// Show a confirmation dialog with the command text and a "trust this directory" checkbox.
    /// Returns true if the user chose to run, false if cancelled.
    private static func showConfirmDialog(command: String, configPath: String, repoRoot: String?) -> Bool {
        let alert = confirmCommandAlertFactory()
        alert.messageText = String(
            localized: "dialog.cmuxConfig.confirmCommand.title",
            defaultValue: "Run Command"
        )
        let messageFormat = String(
            localized: "dialog.cmuxConfig.confirmCommand.messageWithCommand",
            defaultValue: "This will run the following command:\n\n%@"
        )
        var message = String(format: messageFormat, sanitizeForDisplay(command))
        if let repoRoot {
            let repoRootFormat = String(
                localized: "dialog.cmuxConfig.confirmCommand.repoRootNote",
                defaultValue: "It will run from the current workspace's git repo root:\n\n%@"
            )
            message += "\n\n" + String(format: repoRootFormat, sanitizeForDisplay(repoRoot))
        }
        alert.informativeText = message
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

    private static func showRepoRootFallbackDialog() -> Bool {
        let alert = repoRootFallbackAlertFactory()
        alert.messageText = String(
            localized: "dialog.cmuxConfig.repoRootFallback.title",
            defaultValue: "Git Repository Not Found"
        )
        alert.informativeText = String(
            localized: "dialog.cmuxConfig.repoRootFallback.message",
            defaultValue: "This command is configured to run from the project repo root, but the current workspace is not inside a git repository. Run it in the current terminal directory instead?"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.repoRootFallback.runHere",
            defaultValue: "Run in Current Directory"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.cancel",
            defaultValue: "Cancel"
        ))
        return alert.runModal() == .alertFirstButtonReturn
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

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

#if DEBUG
extension CmuxConfigExecutor {
    static func configureHooksForTesting(
        confirmCommandAlertFactory: (() -> NSAlert)? = nil,
        repoRootFallbackAlertFactory: (() -> NSAlert)? = nil,
        commandSender: ((TerminalPanel, String) -> Void)? = nil
    ) {
        self.confirmCommandAlertFactory = confirmCommandAlertFactory ?? { NSAlert() }
        self.repoRootFallbackAlertFactory = repoRootFallbackAlertFactory ?? { NSAlert() }
        self.commandSender = commandSender ?? { terminal, text in
            terminal.sendInput(text)
        }
    }

    static func resetHooksForTesting() {
        confirmCommandAlertFactory = { NSAlert() }
        repoRootFallbackAlertFactory = { NSAlert() }
        commandSender = { terminal, text in
            terminal.sendInput(text)
        }
    }
}
#endif
