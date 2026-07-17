import Foundation

extension CmuxConfigStore {
    func resolvedProjectWorktreesCreateAction() -> CmuxResolvedConfigAction? {
        resolvedProjectWorktreesCreateActionCache
    }

    func resolvedProjectWorktreesOpenAction() -> CmuxResolvedConfigAction? {
        resolvedProjectWorktreesOpenActionCache
    }

    func resolvedProjectWorktreesAction(
        id: String?,
        sourcePath: String?,
        actions: [String: CmuxResolvedConfigAction],
        commands: [CmuxCommandDefinition],
        commandSourcePaths: [String: String],
        settingName: String
    ) -> (action: CmuxResolvedConfigAction?, issue: CmuxConfigIssue?) {
        guard let id else { return (nil, nil) }
        let canonicalID = CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
        guard let action = actions[canonicalID] else {
            return unresolvedProjectWorktreesAction(
                kind: .newWorkspaceActionNotFound,
                settingName: settingName,
                commandName: id,
                sourcePath: sourcePath
            )
        }
        guard let commandName = action.workspaceCommandName else {
            return (action, nil)
        }
        guard let command = commands.first(where: { $0.name == commandName }) else {
            return unresolvedProjectWorktreesAction(
                kind: .newWorkspaceCommandNotFound,
                settingName: settingName,
                commandName: commandName,
                sourcePath: action.actionSourcePath ?? sourcePath
            )
        }
        guard command.workspace != nil else {
            return unresolvedProjectWorktreesAction(
                kind: .newWorkspaceCommandRequiresWorkspace,
                settingName: settingName,
                commandName: commandName,
                sourcePath: commandSourcePaths[command.id] ?? action.actionSourcePath ?? sourcePath
            )
        }
        return (action, nil)
    }

    private func unresolvedProjectWorktreesAction(
        kind: CmuxConfigIssue.Kind,
        settingName: String,
        commandName: String,
        sourcePath: String?
    ) -> (action: CmuxResolvedConfigAction?, issue: CmuxConfigIssue?) {
        let issue = CmuxConfigIssue(
            kind: kind,
            settingName: settingName,
            commandName: commandName,
            sourcePath: sourcePath
        )
        NSLog("[CmuxConfig] %@", issue.logMessage)
        return (nil, issue)
    }
}
