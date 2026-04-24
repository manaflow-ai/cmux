import AppKit
import Foundation

@MainActor
struct CmuxConfigExecutor {

    @discardableResult
    static func execute(
        command: CmuxCommandDefinition,
        tabManager: TabManager,
        baseCwd: String,
        configSourcePath: String?,
        globalConfigPath: String,
        displayTitle: String? = nil,
        actionID: String? = nil,
        icon: CmuxButtonIcon? = nil,
        iconSourcePath: String? = nil,
        presentingWindow: NSWindow? = nil,
        onExecuted: (() -> Void)? = nil
    ) -> Bool {
        if let workspace = command.workspace {
            return authorizeProjectActionIfNeeded(
                descriptor: workspaceTrustDescriptor(
                    command: command,
                    actionID: actionID ?? command.id,
                    configSourcePath: configSourcePath,
                    icon: icon,
                    iconSourcePath: iconSourcePath,
                    globalConfigPath: globalConfigPath
                ),
                confirm: command.confirm ?? false,
                configSourcePath: configSourcePath,
                globalConfigPath: globalConfigPath,
                displayCommand: command.name,
                displayTitle: displayTitle ?? command.name,
                presentingWindow: presentingWindow
            ) {
                executeWorkspaceCommand(
                    command: command,
                    workspace: workspace,
                    tabManager: tabManager,
                    baseCwd: baseCwd
                )
                onExecuted?()
            }
        } else if let rawCommand = command.command {
            let targetTerminal = tabManager.selectedWorkspace?.focusedTerminalPanel
            guard let targetTerminal else { return false }
            return prepareShellInputIfAuthorized(
                rawCommand,
                confirm: command.confirm ?? false,
                actionID: actionID ?? command.id,
                target: .currentTerminal,
                configSourcePath: configSourcePath,
                globalConfigPath: globalConfigPath,
                displayTitle: displayTitle ?? command.name,
                icon: icon,
                iconSourcePath: iconSourcePath,
                presentingWindow: presentingWindow
            ) { shellInput in
                targetTerminal.sendInput(shellInput)
                onExecuted?()
            }
        }
        return false
    }

    @discardableResult
    static func execute(
        action: CmuxResolvedConfigAction,
        commands: [CmuxCommandDefinition],
        commandSourcePaths: [String: String],
        tabManager: TabManager,
        baseCwd: String,
        globalConfigPath: String,
        presentingWindow: NSWindow? = nil,
        onExecuted: (() -> Void)? = nil
    ) -> Bool {
        if let commandName = action.workspaceCommandName,
           let command = commands.first(where: { $0.name == commandName }) {
            guard command.workspace != nil else { return false }
            return execute(
                command: command,
                tabManager: tabManager,
                baseCwd: baseCwd,
                configSourcePath: commandSourcePaths[command.id] ?? action.actionSourcePath,
                globalConfigPath: globalConfigPath,
                displayTitle: action.title,
                actionID: action.id,
                icon: action.icon,
                iconSourcePath: action.iconSourcePath,
                presentingWindow: presentingWindow,
                onExecuted: onExecuted
            )
        }

        guard let command = action.terminalCommand else { return false }
        let target = action.terminalCommandTarget ?? .newTabInCurrentPane
        let targetTerminal = (target == .currentTerminal) ? tabManager.selectedWorkspace?.focusedTerminalPanel : nil
        let targetWorkspace = (target == .newTabInCurrentPane) ? tabManager.selectedWorkspace : nil
        return prepareShellInputIfAuthorized(
            command,
            confirm: action.confirm ?? false,
            actionID: action.id,
            target: target,
            configSourcePath: action.actionSourcePath,
            globalConfigPath: globalConfigPath,
            displayTitle: action.title,
            icon: action.icon,
            iconSourcePath: action.iconSourcePath,
            presentingWindow: presentingWindow
        ) { shellInput in
            switch target {
            case .currentTerminal:
                targetTerminal?.sendInput(shellInput)
            case .newTabInCurrentPane:
                targetWorkspace?.clearSplitZoom()
                targetWorkspace?.newTerminalSurfaceInFocusedPane(focus: true, initialInput: shellInput)
            }
            onExecuted?()
        }
    }

    @discardableResult
    static func prepareShellInputIfAuthorized(
        _ rawCommand: String,
        confirm: Bool,
        actionID: String,
        target: CmuxConfigTerminalCommandTarget,
        configSourcePath: String?,
        globalConfigPath: String,
        displayTitle: String? = nil,
        icon: CmuxButtonIcon? = nil,
        iconSourcePath: String? = nil,
        presentingWindow: NSWindow? = nil,
        onAuthorized: @escaping (String) -> Void
    ) -> Bool {
        let shellCommand = sanitizeForDisplay(rawCommand)
        guard !shellCommand.isEmpty else { return false }

        let descriptor = terminalTrustDescriptor(
            command: shellCommand,
            actionID: actionID,
            target: target,
            configSourcePath: configSourcePath,
            icon: icon,
            iconSourcePath: iconSourcePath,
            globalConfigPath: globalConfigPath
        )
        return authorizeProjectActionIfNeeded(
            descriptor: descriptor,
            confirm: confirm,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath,
            displayCommand: shellCommand,
            displayTitle: displayTitle,
            presentingWindow: presentingWindow
        ) {
            onAuthorized(shellCommand + "\n")
        }
    }

    @discardableResult
    private static func authorizeProjectActionIfNeeded(
        descriptor: CmuxActionTrustDescriptor,
        confirm: Bool,
        configSourcePath: String?,
        globalConfigPath: String,
        displayCommand: String,
        displayTitle: String?,
        presentingWindow: NSWindow?,
        onAuthorized: @escaping () -> Void
    ) -> Bool {
        let sourcePath = configSourcePath.map(canonicalPath)
        let canonicalGlobalConfigPath = canonicalPath(globalConfigPath)
        let isTrusted = CmuxActionTrust.shared.isTrusted(descriptor)
        let resolvedPresentingWindow = presentingWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let sourcePath,
              sourcePath != canonicalGlobalConfigPath else {
            onAuthorized()
            return true
        }
        if !confirm, isTrusted {
            onAuthorized()
            return true
        }
        if let resolvedPresentingWindow {
            presentConfirmDialog(
                command: displayCommand,
                displayTitle: displayTitle,
                descriptor: descriptor,
                configPath: sourcePath,
                presentingWindow: resolvedPresentingWindow
            ) { allowed in
                if allowed {
                    onAuthorized()
                }
            }
            return true
        }
        let allowed = runConfirmDialog(
            command: displayCommand,
            displayTitle: displayTitle,
            descriptor: descriptor,
            configPath: sourcePath
        )
        if allowed {
            onAuthorized()
        }
        return allowed
    }

    private static func presentConfirmDialog(
        command: String,
        displayTitle: String?,
        descriptor: CmuxActionTrustDescriptor,
        configPath: String,
        presentingWindow: NSWindow,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = makeConfirmDialog(
            command: command,
            displayTitle: displayTitle,
            configPath: configPath
        )
        alert.beginSheetModal(for: presentingWindow) { response in
            completion(handleConfirmDialogResponse(response, descriptor: descriptor))
        }
    }

    private static func runConfirmDialog(
        command: String,
        displayTitle: String?,
        descriptor: CmuxActionTrustDescriptor,
        configPath: String
    ) -> Bool {
        let alert = makeConfirmDialog(
            command: command,
            displayTitle: displayTitle,
            configPath: configPath
        )
        return handleConfirmDialogResponse(alert.runModal(), descriptor: descriptor)
    }

    private static func makeConfirmDialog(
        command: String,
        displayTitle: String?,
        configPath: String
    ) -> NSAlert {
        let alert = NSAlert()
        let trimmedDisplayTitle = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.messageText = (trimmedDisplayTitle?.isEmpty == false)
            ? trimmedDisplayTitle!
            : String(
                localized: "dialog.cmuxConfig.confirmCommand.title",
                defaultValue: "Run Project Action?"
            )
        let messageFormat = String(
            localized: "dialog.cmuxConfig.confirmCommand.messageWithCommand",
            defaultValue: "This project action comes from:\n\n%@\n\nIt will run:\n\n%@"
        )
        alert.informativeText = String(
            format: messageFormat,
            sanitizeForDisplay(configPath),
            sanitizeForDisplay(command)
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.run",
            defaultValue: "Run Once"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.trustAndRun",
            defaultValue: "Trust and Run"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.confirmCommand.cancel",
            defaultValue: "Cancel"
        ))
        return alert
    }

    private static func handleConfirmDialogResponse(
        _ response: NSApplication.ModalResponse,
        descriptor: CmuxActionTrustDescriptor
    ) -> Bool {
        switch response {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            CmuxActionTrust.shared.trust(descriptor)
            return true
        default:
            return false
        }
    }

    private static func terminalTrustDescriptor(
        command: String,
        actionID: String,
        target: CmuxConfigTerminalCommandTarget,
        configSourcePath: String?,
        icon: CmuxButtonIcon?,
        iconSourcePath: String?,
        globalConfigPath: String
    ) -> CmuxActionTrustDescriptor {
        CmuxActionTrustDescriptor(
            actionID: actionID,
            kind: "terminalCommand",
            command: command,
            target: target.rawValue,
            workspaceCommand: nil,
            configPath: configSourcePath.map(canonicalPath),
            projectRoot: configSourcePath.map { canonicalPath(CmuxButtonIcon.projectRoot(forConfigPath: $0)) },
            iconFingerprint: icon?.projectLocalImageFingerprint(
                configSourcePath: iconSourcePath ?? configSourcePath,
                globalConfigPath: globalConfigPath
            )
        )
    }

    private static func workspaceTrustDescriptor(
        command: CmuxCommandDefinition,
        actionID: String,
        configSourcePath: String?,
        icon: CmuxButtonIcon?,
        iconSourcePath: String?,
        globalConfigPath: String
    ) -> CmuxActionTrustDescriptor {
        CmuxActionTrustDescriptor(
            actionID: actionID,
            kind: "workspaceCommand",
            command: nil,
            target: nil,
            workspaceCommand: command,
            configPath: configSourcePath.map(canonicalPath),
            projectRoot: configSourcePath.map { canonicalPath(CmuxButtonIcon.projectRoot(forConfigPath: $0)) },
            iconFingerprint: icon?.projectLocalImageFingerprint(
                configSourcePath: iconSourcePath ?? configSourcePath,
                globalConfigPath: globalConfigPath
            )
        )
    }

    static func isTrustedSurfaceButton(
        _ button: CmuxSurfaceTabBarButton,
        workspaceCommand: CmuxResolvedCommand?,
        terminalCommandSourcePath: String?,
        surfaceTabBarConfigSourcePath: String?,
        globalConfigPath: String
    ) -> Bool {
        guard let descriptor = surfaceButtonTrustDescriptor(
            button,
            workspaceCommand: workspaceCommand,
            terminalCommandSourcePath: terminalCommandSourcePath,
            surfaceTabBarConfigSourcePath: surfaceTabBarConfigSourcePath,
            globalConfigPath: globalConfigPath
        ) else {
            return true
        }
        guard let configPath = descriptor.configPath,
              configPath != canonicalPath(globalConfigPath) else {
            return true
        }
        return CmuxActionTrust.shared.isTrusted(descriptor)
    }

    private static func surfaceButtonTrustDescriptor(
        _ button: CmuxSurfaceTabBarButton,
        workspaceCommand: CmuxResolvedCommand?,
        terminalCommandSourcePath: String?,
        surfaceTabBarConfigSourcePath: String?,
        globalConfigPath: String
    ) -> CmuxActionTrustDescriptor? {
        let configSourcePath = terminalCommandSourcePath
            ?? workspaceCommand?.sourcePath
            ?? button.actionSourcePath
            ?? surfaceTabBarConfigSourcePath
        let iconSourcePath = button.iconSourcePath
            ?? (button.icon == nil ? nil : surfaceTabBarConfigSourcePath)
        let resolvedIcon = button.icon ?? button.action.defaultButtonIcon

        if let workspaceCommand {
            return workspaceTrustDescriptor(
                command: workspaceCommand.command,
                actionID: button.id,
                configSourcePath: configSourcePath,
                icon: resolvedIcon,
                iconSourcePath: iconSourcePath,
                globalConfigPath: globalConfigPath
            )
        }

        guard let terminalCommand = button.terminalCommand else {
            return nil
        }

        return terminalTrustDescriptor(
            command: sanitizeForDisplay(terminalCommand),
            actionID: button.id,
            target: button.resolvedTerminalCommandTarget,
            configSourcePath: configSourcePath,
            icon: resolvedIcon,
            iconSourcePath: iconSourcePath,
            globalConfigPath: globalConfigPath
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
