import AppKit
import Bonsplit
import Foundation

/// Observable lifecycle state for a configured cmux action.
///
/// Boolean execution APIs remain available for shortcut and menu call sites,
/// while command-palette automation uses this value to distinguish completed
/// work from queued work and UI that owns the remaining interaction.
enum CmuxConfiguredActionExecutionOutcome: Sendable, Equatable {
    case completed
    case queued
    case presented
    case failed

    var isAccepted: Bool {
        switch self {
        case .completed, .queued, .presented:
            true
        case .failed:
            false
        }
    }
}

/// Immutable model identity for a configured action's workspace and panel.
///
/// Callers resolve routing once and pass the resulting IDs here. The executor
/// resolves and captures the live models before any asynchronous confirmation
/// sheet, so a later focus change cannot redirect the authorized action.
struct CmuxActionModelTarget: Sendable, Equatable {
    let workspaceID: UUID?
    let panelID: UUID?

    init(workspaceID: UUID?, panelID: UUID?) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }
}

@MainActor
struct CmuxConfigExecutor {

    private struct ResolvedModelTarget {
        let workspace: Workspace?
        let panelID: UUID?
    }

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
        modelTarget: CmuxActionModelTarget? = nil,
        onExecuted: (() -> Void)? = nil
    ) -> Bool {
        executeOutcome(
            command: command,
            tabManager: tabManager,
            baseCwd: baseCwd,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath,
            displayTitle: displayTitle,
            actionID: actionID,
            icon: icon,
            iconSourcePath: iconSourcePath,
            presentingWindow: presentingWindow,
            modelTarget: modelTarget,
            onExecuted: onExecuted
        ).isAccepted
    }

    static func executeOutcome(
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
        modelTarget: CmuxActionModelTarget? = nil,
        selectWorkspace: Bool = true,
        alertFactory: () -> NSAlert = { NSAlert() },
        isExecutionTargetAvailable: @escaping () -> Bool = { true },
        onExecuted: (() -> Void)? = nil
    ) -> CmuxConfiguredActionExecutionOutcome {
        guard isExecutionTargetAvailable() else { return .failed }
        if let workspace = command.workspace {
            let sourceWorkspaceID: UUID?
            let sourcePanelID = modelTarget?.panelID
            if let modelTarget {
                guard let workspaceID = modelTarget.workspaceID,
                      let sourceWorkspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
                      modelTarget.panelID.map({ sourceWorkspace.panels[$0] != nil }) ?? true else {
                    return .failed
                }
                sourceWorkspaceID = workspaceID
            } else {
                sourceWorkspaceID = tabManager.selectedWorkspace?.id
            }
            return authorizeProjectActionOutcomeIfNeeded(
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
                displayCommand: workspaceShellDisclosure(command),
                displayTitle: displayTitle ?? command.name,
                presentingWindow: presentingWindow,
                alertFactory: alertFactory
            ) {
                guard isExecutionTargetAvailable() else { return .failed }
                if let sourceWorkspaceID {
                    guard let sourceWorkspace = tabManager.tabs.first(where: { $0.id == sourceWorkspaceID }),
                          sourcePanelID.map({ sourceWorkspace.panels[$0] != nil }) ?? true else {
                        return .failed
                    }
                }
                guard executeWorkspaceCommand(
                    command: command,
                    workspace: workspace,
                    tabManager: tabManager,
                    baseCwd: baseCwd,
                    sourceWorkspaceID: sourceWorkspaceID,
                    select: selectWorkspace
                ) else { return .failed }
                onExecuted?()
                return .completed
            }
        } else if let rawCommand = command.command {
            let resolvedTarget = resolveModelTarget(modelTarget, tabManager: tabManager)
            guard let targetWorkspace = resolvedTarget.workspace,
                  let targetPanelID = resolvedTarget.panelID,
                  let targetTerminal = targetWorkspace.terminalPanel(for: targetPanelID) else {
                return .failed
            }
            return prepareShellInputOutcomeIfAuthorized(
                rawCommand,
                confirm: command.confirm ?? false,
                actionID: actionID ?? command.id,
                target: .currentTerminal,
                configSourcePath: configSourcePath,
                globalConfigPath: globalConfigPath,
                displayTitle: displayTitle ?? command.name,
                icon: icon,
                iconSourcePath: iconSourcePath,
                presentingWindow: presentingWindow,
                alertFactory: alertFactory
            ) { shellInput in
                guard isExecutionTargetAvailable(),
                      tabManager.tabs.contains(where: { $0 === targetWorkspace }),
                      targetWorkspace.terminalPanel(for: targetPanelID) === targetTerminal else {
                    return
                }
                targetTerminal.sendInput(shellInput)
                onExecuted?()
            }
        }
        return .failed
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
        modelTarget: CmuxActionModelTarget? = nil,
        selectWorkspace: Bool = true,
        onExecuted: (() -> Void)? = nil
    ) -> Bool {
        executeOutcome(
            action: action,
            commands: commands,
            commandSourcePaths: commandSourcePaths,
            tabManager: tabManager,
            baseCwd: baseCwd,
            globalConfigPath: globalConfigPath,
            presentingWindow: presentingWindow,
            modelTarget: modelTarget,
            selectWorkspace: selectWorkspace,
            onExecuted: onExecuted
        ).isAccepted
    }

    static func executeOutcome(
        action: CmuxResolvedConfigAction,
        commands: [CmuxCommandDefinition],
        commandSourcePaths: [String: String],
        tabManager: TabManager,
        baseCwd: String,
        globalConfigPath: String,
        presentingWindow: NSWindow? = nil,
        modelTarget: CmuxActionModelTarget? = nil,
        selectWorkspace: Bool = true,
        alertFactory: () -> NSAlert = { NSAlert() },
        isExecutionTargetAvailable: @escaping () -> Bool = { true },
        onExecuted: (() -> Void)? = nil
    ) -> CmuxConfiguredActionExecutionOutcome {
        guard isExecutionTargetAvailable() else { return .failed }
        if let syntheticCommand = action.inlineWorkspaceSyntheticCommand {
            // Inline `type: "workspace"` actions reuse the named-command path via a
            // synthetic definition so trust, restart, confirm, and layout behavior
            // stay identical.
            return executeOutcome(
                command: syntheticCommand,
                tabManager: tabManager,
                baseCwd: baseCwd,
                configSourcePath: action.actionSourcePath,
                globalConfigPath: globalConfigPath,
                displayTitle: action.title,
                actionID: action.id,
                icon: action.icon,
                iconSourcePath: action.iconSourcePath,
                presentingWindow: presentingWindow,
                modelTarget: modelTarget,
                selectWorkspace: selectWorkspace,
                alertFactory: alertFactory,
                isExecutionTargetAvailable: isExecutionTargetAvailable,
                onExecuted: onExecuted
            )
        }

        if let commandName = action.workspaceCommandName,
           let command = commands.first(where: { $0.name == commandName }) {
            guard command.workspace != nil else { return .failed }
            return executeOutcome(
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
                modelTarget: modelTarget,
                selectWorkspace: selectWorkspace,
                alertFactory: alertFactory,
                isExecutionTargetAvailable: isExecutionTargetAvailable,
                onExecuted: onExecuted
            )
        }

        guard let command = action.terminalCommand else { return .failed }
        let target = action.terminalCommandTarget ?? .newTabInCurrentPane
        let resolvedTarget = resolveModelTarget(modelTarget, tabManager: tabManager)
        guard let targetWorkspace = resolvedTarget.workspace,
              let targetPanelID = resolvedTarget.panelID else {
            return .failed
        }
        let targetTerminal: TerminalPanel?
        let targetPaneID: PaneID?
        switch target {
        case .currentTerminal:
            guard let terminal = targetWorkspace.terminalPanel(for: targetPanelID) else {
                return .failed
            }
            targetTerminal = terminal
            targetPaneID = nil
        case .newTabInCurrentPane:
            guard let paneID = targetWorkspace.paneId(forPanelId: targetPanelID) else {
                return .failed
            }
            targetTerminal = nil
            targetPaneID = paneID
        }
        return prepareShellInputOutcomeIfAuthorized(
            command,
            confirm: action.confirm ?? false,
            actionID: action.id,
            target: target,
            configSourcePath: action.actionSourcePath,
            globalConfigPath: globalConfigPath,
            displayTitle: action.title,
            icon: action.icon,
            iconSourcePath: action.iconSourcePath,
            presentingWindow: presentingWindow,
            alertFactory: alertFactory
        ) { shellInput in
            guard isExecutionTargetAvailable(),
                  tabManager.tabs.contains(where: { $0 === targetWorkspace }) else {
                return
            }
            switch target {
            case .currentTerminal:
                guard let targetTerminal,
                      targetWorkspace.terminalPanel(for: targetPanelID) === targetTerminal else {
                    return
                }
                targetTerminal.sendInput(shellInput)
            case .newTabInCurrentPane:
                guard let targetPaneID,
                      targetWorkspace.panels[targetPanelID] != nil,
                      targetWorkspace.paneId(forPanelId: targetPanelID) == targetPaneID else {
                    return
                }
                targetWorkspace.clearSplitZoom()
                targetWorkspace.newTerminalSurface(
                    inPane: targetPaneID,
                    focus: true,
                    initialInput: shellInput,
                    inheritWorkingDirectoryFallback: true
                )
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
        prepareShellInputOutcomeIfAuthorized(
            rawCommand,
            confirm: confirm,
            actionID: actionID,
            target: target,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath,
            displayTitle: displayTitle,
            icon: icon,
            iconSourcePath: iconSourcePath,
            presentingWindow: presentingWindow,
            onAuthorized: onAuthorized
        ).isAccepted
    }

    static func prepareShellInputOutcomeIfAuthorized(
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
        alertFactory: () -> NSAlert = { NSAlert() },
        onAuthorized: @escaping (String) -> Void
    ) -> CmuxConfiguredActionExecutionOutcome {
        let shellCommand = sanitizeForDisplay(rawCommand)
        guard !shellCommand.isEmpty else { return .failed }

        let descriptor = terminalTrustDescriptor(
            command: shellCommand,
            actionID: actionID,
            target: target,
            configSourcePath: configSourcePath,
            icon: icon,
            iconSourcePath: iconSourcePath,
            globalConfigPath: globalConfigPath
        )
        return authorizeProjectActionOutcomeIfNeeded(
            descriptor: descriptor,
            confirm: confirm,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath,
            displayCommand: shellCommand,
            displayTitle: displayTitle,
            presentingWindow: presentingWindow,
            alertFactory: alertFactory
        ) {
            onAuthorized(shellCommand + "\n")
            return .completed
        }
    }

    @discardableResult
    static func authorizeProjectAutomationIfNeeded(
        descriptor: CmuxActionTrustDescriptor,
        confirm: Bool,
        configSourcePath: String?,
        globalConfigPath: String,
        displayCommand: String,
        displayTitle: String? = nil,
        presentingWindow: NSWindow? = nil,
        onAuthorized: @escaping () -> Void,
        onDenied: (() -> Void)? = nil
    ) -> Bool {
        authorizeProjectAutomationOutcomeIfNeeded(
            descriptor: descriptor,
            confirm: confirm,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath,
            displayCommand: displayCommand,
            displayTitle: displayTitle,
            presentingWindow: presentingWindow,
            onAuthorized: onAuthorized,
            onDenied: onDenied
        ).isAccepted
    }

    static func authorizeProjectAutomationOutcomeIfNeeded(
        descriptor: CmuxActionTrustDescriptor,
        confirm: Bool,
        configSourcePath: String?,
        globalConfigPath: String,
        displayCommand: String,
        displayTitle: String? = nil,
        presentingWindow: NSWindow? = nil,
        fallbackPresentingWindowProvider: @escaping () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow },
        alertFactory: @escaping () -> NSAlert = { NSAlert() },
        onAuthorized: @escaping () -> Void,
        onDenied: (() -> Void)? = nil
    ) -> CmuxConfiguredActionExecutionOutcome {
        authorizeProjectActionOutcomeIfNeeded(
            descriptor: descriptor,
            confirm: confirm,
            configSourcePath: configSourcePath,
            globalConfigPath: globalConfigPath,
            displayCommand: displayCommand,
            displayTitle: displayTitle,
            presentingWindow: presentingWindow,
            fallbackPresentingWindowProvider: fallbackPresentingWindowProvider,
            alertFactory: alertFactory,
            onAuthorized: {
                onAuthorized()
                return .completed
            },
            onDenied: onDenied
        )
    }

    @discardableResult
    private static func authorizeProjectActionOutcomeIfNeeded(
        descriptor: CmuxActionTrustDescriptor,
        confirm: Bool,
        configSourcePath: String?,
        globalConfigPath: String,
        displayCommand: String,
        displayTitle: String?,
        presentingWindow: NSWindow?,
        fallbackPresentingWindowProvider: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow },
        alertFactory: () -> NSAlert = { NSAlert() },
        onAuthorized: @escaping () -> CmuxConfiguredActionExecutionOutcome,
        onDenied: (() -> Void)? = nil
    ) -> CmuxConfiguredActionExecutionOutcome {
        let sourcePath = configSourcePath.map(canonicalPath)
        let canonicalGlobalConfigPath = canonicalPath(globalConfigPath)
        let isTrusted = CmuxActionTrust.shared.isTrusted(descriptor)
        let resolvedPresentingWindow = presentingWindow ?? fallbackPresentingWindowProvider()
        guard let sourcePath,
              sourcePath != canonicalGlobalConfigPath else {
            return onAuthorized()
        }
        if !confirm, isTrusted {
            return onAuthorized()
        }
        if let resolvedPresentingWindow {
            presentConfirmDialog(
                command: displayCommand,
                displayTitle: displayTitle,
                descriptor: descriptor,
                configPath: sourcePath,
                presentingWindow: resolvedPresentingWindow,
                alertFactory: alertFactory
            ) { allowed in
                if allowed {
                    _ = onAuthorized()
                } else {
                    onDenied?()
                }
            }
            return .presented
        }
        let allowed = runConfirmDialog(
            command: displayCommand,
            displayTitle: displayTitle,
            descriptor: descriptor,
            configPath: sourcePath,
            alertFactory: alertFactory
        )
        if allowed {
            return onAuthorized()
        } else {
            onDenied?()
            return .failed
        }
    }

    private static func resolveModelTarget(
        _ target: CmuxActionModelTarget?,
        tabManager: TabManager
    ) -> ResolvedModelTarget {
        if let target {
            let workspace = target.workspaceID.flatMap { workspaceID in
                tabManager.tabs.first(where: { $0.id == workspaceID })
            }
            return ResolvedModelTarget(workspace: workspace, panelID: target.panelID)
        }

        let workspace = tabManager.selectedWorkspace
        return ResolvedModelTarget(workspace: workspace, panelID: workspace?.focusedPanelId)
    }

    private static func presentConfirmDialog(
        command: String,
        displayTitle: String?,
        descriptor: CmuxActionTrustDescriptor,
        configPath: String,
        presentingWindow: NSWindow,
        alertFactory: () -> NSAlert,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = makeConfirmDialog(
            command: command,
            displayTitle: displayTitle,
            configPath: configPath,
            alertFactory: alertFactory
        )
        let content = CmuxAlertContent(
            flattenedText: alert.informativeText,
            separatingScrollableDetails: sanitizeForDisplay(command)
        )
        content.apply(to: alert, presentingWindow: presentingWindow)
        alert.beginSheetModal(for: presentingWindow) { response in
            completion(handleConfirmDialogResponse(response, descriptor: descriptor))
        }
    }

    private static func runConfirmDialog(
        command: String,
        displayTitle: String?,
        descriptor: CmuxActionTrustDescriptor,
        configPath: String,
        alertFactory: () -> NSAlert
    ) -> Bool {
        let alert = makeConfirmDialog(
            command: command,
            displayTitle: displayTitle,
            configPath: configPath,
            alertFactory: alertFactory
        )
        let content = CmuxAlertContent(
            flattenedText: alert.informativeText,
            separatingScrollableDetails: sanitizeForDisplay(command)
        )
        content.apply(to: alert, presentingWindow: nil)
        return handleConfirmDialogResponse(alert.runModal(), descriptor: descriptor)
    }

    private static func makeConfirmDialog(
        command: String,
        displayTitle: String?,
        configPath: String,
        alertFactory: () -> NSAlert
    ) -> NSAlert {
        let alert = alertFactory()
        // Titles come from project-local configs too — strip bidi/zero-width
        // controls like the command body below, so the header can't be spoofed.
        let trimmedDisplayTitle = displayTitle.map(sanitizeForDisplay)
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

        if let inlineWorkspaceCommand = button.inlineWorkspaceSyntheticCommand {
            return workspaceTrustDescriptor(
                command: inlineWorkspaceCommand,
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
}
