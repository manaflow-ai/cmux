import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - New Workspace Resolution
extension CmuxConfigStore {
    func resolvedNewWorkspaceCommand() -> CmuxResolvedCommand? {
        resolvedNewWorkspaceCommandCache
    }

    func resolvedNewWorkspaceAction() -> CmuxResolvedConfigAction? {
        resolvedNewWorkspaceActionCache
    }

    func resolvedConfiguredNewWorkspaceAction(
        actionID: String?,
        actionSourcePath: String?,
        commandName: String?,
        commandSourcePath: String?,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceActionResolution {
        if let actionID {
            let resolvedActionID = canonicalActionID(actionID)
            guard let action = actions[resolvedActionID] else {
                let issue = CmuxConfigIssue(
                    kind: .newWorkspaceActionNotFound,
                    settingName: "ui.newWorkspace.action",
                    commandName: actionID,
                    sourcePath: actionSourcePath
                )
                NSLog("[CmuxConfig] %@", issue.logMessage)
                return NewWorkspaceActionResolution(action: nil, command: nil, issue: issue)
            }
            if let actionCommandName = action.workspaceCommandName {
                let commandResolution = resolvedConfiguredNewWorkspaceCommand(
                    named: actionCommandName,
                    settingName: "ui.newWorkspace.action",
                    settingSourcePath: action.actionSourcePath ?? actionSourcePath,
                    commands: commands,
                    sourcePaths: sourcePaths
                )
                guard commandResolution.issue == nil else {
                    return NewWorkspaceActionResolution(
                        action: nil,
                        command: commandResolution.command,
                        issue: commandResolution.issue
                    )
                }
                return NewWorkspaceActionResolution(
                    action: action,
                    command: commandResolution.command,
                    issue: nil
                )
            }
            return NewWorkspaceActionResolution(action: action, command: nil, issue: nil)
        }

        guard let commandName else {
            return NewWorkspaceActionResolution(action: nil, command: nil, issue: nil)
        }
        let commandResolution = resolvedConfiguredNewWorkspaceCommand(
            named: commandName,
            settingName: "newWorkspaceCommand",
            settingSourcePath: commandSourcePath,
            commands: commands,
            sourcePaths: sourcePaths
        )
        guard let command = commandResolution.command else {
            return NewWorkspaceActionResolution(action: nil, command: nil, issue: commandResolution.issue)
        }
        return NewWorkspaceActionResolution(
            action: CmuxResolvedConfigAction(
                id: command.command.id,
                title: command.command.name,
                subtitle: command.command.description
                    ?? String(localized: "command.cmuxConfig.subtitle", defaultValue: "cmux.json"),
                keywords: command.command.keywords ?? [],
                palette: false,
                shortcut: nil,
                icon: .symbol("rectangle.stack.badge.plus"),
                tooltip: command.command.description,
                action: .workspaceCommand(command.command.name),
                confirm: command.command.confirm,
                terminalCommandTarget: nil,
                actionSourcePath: command.sourcePath,
                iconSourcePath: nil
            ),
            command: command,
            issue: nil
        )
    }

    func resolvedConfigContextMenuItems(
        _ configuredItems: [CmuxConfigContextMenuItem]?,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String],
        settingName: String,
        settingSourcePath: String?
    ) -> ResolvedContextMenuItems {
        guard let configuredItems, !configuredItems.isEmpty else {
            return ResolvedContextMenuItems(items: [], issues: [])
        }
        var resolvedItems: [CmuxResolvedConfigContextMenuItem] = []
        var issues: [CmuxConfigIssue] = []
        resolvedItems.reserveCapacity(configuredItems.count)

        for (index, configuredItem) in configuredItems.enumerated() {
            let itemSettingName = "\(settingName)[\(index)]"
            switch configuredItem {
            case .separator:
                guard !resolvedItems.isEmpty else { continue }
                if let last = resolvedItems.last, case .separator = last {
                    continue
                }
                resolvedItems.append(.separator(id: "\(settingName).separator.\(index)"))
            case .action(let item):
                let resolvedActionID = canonicalActionID(item.action)
                guard let action = actions[resolvedActionID] else {
                    let issue = CmuxConfigIssue(
                        kind: .newWorkspaceActionNotFound,
                        settingName: itemSettingName,
                        commandName: item.action,
                        sourcePath: settingSourcePath
                    )
                    NSLog("[CmuxConfig] %@", issue.logMessage)
                    issues.append(issue)
                    continue
                }
                if let actionCommandName = action.workspaceCommandName {
                    let commandResolution = resolvedConfiguredNewWorkspaceCommand(
                        named: actionCommandName,
                        settingName: itemSettingName,
                        settingSourcePath: action.actionSourcePath ?? settingSourcePath,
                        commands: commands,
                        sourcePaths: sourcePaths
                    )
                    if let issue = commandResolution.issue {
                        issues.append(issue)
                        continue
                    }
                    guard commandResolution.command != nil else {
                        continue
                    }
                }
                resolvedItems.append(
                    .action(
                        CmuxResolvedConfigMenuAction(
                            id: "\(settingName).\(index).\(action.id)",
                            title: sanitizeConfigText(item.title ?? action.title, fallback: action.id),
                            icon: item.icon ?? action.icon,
                            iconSourcePath: item.icon == nil ? action.iconSourcePath : settingSourcePath,
                            tooltip: (item.tooltip ?? action.tooltip).map(sanitizeConfigText),
                            action: action
                        )
                    )
                )
            }
        }

        if let last = resolvedItems.last, case .separator = last {
            resolvedItems.removeLast()
        }
        return ResolvedContextMenuItems(items: resolvedItems, issues: issues)
    }

    private func resolvedConfiguredNewWorkspaceCommand(
        named commandName: String,
        settingName: String,
        settingSourcePath: String?,
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceCommandResolution {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandNotFound,
                settingName: settingName,
                commandName: commandName,
                sourcePath: settingSourcePath
            )
        }
        guard command.workspace != nil else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandRequiresWorkspace,
                settingName: settingName,
                commandName: commandName,
                sourcePath: sourcePaths[command.id] ?? settingSourcePath
            )
        }
        return NewWorkspaceCommandResolution(
            command: CmuxResolvedCommand(command: command, sourcePath: sourcePaths[command.id]),
            issue: nil
        )
    }

    private func newWorkspaceResolutionIssue(
        kind: CmuxConfigIssue.Kind,
        settingName: String,
        commandName: String?,
        sourcePath: String?
    ) -> NewWorkspaceCommandResolution {
        let issue = CmuxConfigIssue(
            kind: kind,
            settingName: settingName,
            commandName: commandName,
            sourcePath: sourcePath
        )
        NSLog("[CmuxConfig] %@", issue.logMessage)
        return NewWorkspaceCommandResolution(command: nil, issue: issue)
    }

    private func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String
    ) -> CmuxResolvedCommand? {
        resolvedWorkspaceCommand(
            named: commandName,
            settingName: settingName,
            commands: loadedCommands,
            sourcePaths: commandSourcePaths
        )
    }

    func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String,
        commands: [CmuxCommandDefinition],
        sourcePaths: [String: String]
    ) -> CmuxResolvedCommand? {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            NSLog("[CmuxConfig] %@ '%@' does not match any loaded command", settingName, commandName)
            return nil
        }
        guard command.workspace != nil else {
            NSLog("[CmuxConfig] %@ '%@' must reference a workspace command", settingName, commandName)
            return nil
        }
        return CmuxResolvedCommand(command: command, sourcePath: sourcePaths[command.id])
    }

    // MARK: - Parsing

}
