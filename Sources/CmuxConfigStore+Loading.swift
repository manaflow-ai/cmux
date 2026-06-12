import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Config Discovery & Loading
extension CmuxConfigStore {
    func wireDirectoryTracking(tabManager: TabManager) {
        trackingCancellables.removeAll()
        self.tabManager = tabManager

        tabManager.selectedTabIdPublisher
            .compactMap { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0.id == $1.id })
            .map { workspace -> AnyPublisher<String?, Never> in
                workspace.surfaceTabBarDirectoryPublisher
            }
            .switchToLatest()
            .removeDuplicates()
            .sink { [weak self] directory in
                self?.updateLocalConfigPath(directory)
            }
            .store(in: &trackingCancellables)

        tabManager.tabsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySurfaceTabBarButtonsToCurrentManager()
            }
            .store(in: &trackingCancellables)

        updateLocalConfigPath(tabManager.selectedWorkspace?.surfaceTabBarDirectory)
    }

    private func updateLocalConfigPath(_ directory: String?) {
        let newPath: String?
        if let directory, !directory.isEmpty {
            localConfigSearchDirectory = directory
            newPath = resolvedLocalConfigPath(startingFrom: directory)
        } else {
            localConfigSearchDirectory = nil
            newPath = nil
        }

        guard newPath != localConfigPath else { return }
        stopLocalFileWatcher()
        localConfigPath = newPath
        if fileWatchingEnabled, newPath != nil {
            startLocalFileWatcher()
        }
        loadAll()
    }

    func resolvedLocalConfigPath(startingFrom directory: String) -> String {
        findCmuxConfig(startingFrom: directory)
            ?? defaultLocalConfigPath(startingFrom: directory)
    }

    private func defaultLocalConfigPath(startingFrom directory: String) -> String {
        (((directory as NSString).appendingPathComponent(".cmux") as NSString)
            .appendingPathComponent("cmux.json"))
    }

    private func findCmuxConfig(startingFrom directory: String) -> String? {
        var current = directory
        let fs = FileManager.default
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json")
            ]
            for candidate in candidates where fs.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    func findCmuxConfigHierarchy(startingFrom directory: String) -> [String] {
        var current = directory
        let fs = FileManager.default
        var paths: [String] = []
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json")
            ]
            if let candidate = candidates.first(where: { fs.fileExists(atPath: $0) }) {
                paths.append(candidate)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return paths.reversed()
    }

    func loadAll() {
        var commands: [CmuxCommandDefinition] = []
        var seenNames = Set<String>()
        var sourcePaths: [String: String] = [:]
        var configuredNewWorkspaceCommandName: String?
        var configuredNewWorkspaceCommandSourcePath: String?
        var configuredNewWorkspaceActionID: String?
        var configuredNewWorkspaceActionSourcePath: String?
        var configuredNewWorkspaceContextMenu: [CmuxConfigContextMenuItem]?
        var configuredNewWorkspaceContextMenuSourcePath: String?
        var configuredSurfaceTabBarButtons: [CmuxSurfaceTabBarButton]?
        var configuredSurfaceTabBarButtonSourcePath: String?
        let localPath = localConfigPath
        let localParseResult = localPath.map { parseConfig(at: $0) }
        let globalParseResult = parseConfig(at: globalConfigPath)
        let localConfig = localParseResult?.config
        let globalConfig = globalParseResult.config
        let localHookPaths = resolvedLocalNotificationHookPaths(fallbackLocalPath: localPath)
        let localHookParseResults = localHookPaths.map { path in
            (path: path, result: parseConfig(at: path))
        }
        var issues = [CmuxConfigIssue]()
        if let issue = localParseResult?.issue {
            issues.append(issue)
        }
        if let issue = globalParseResult.issue {
            issues.append(issue)
        }
        for hookParseResult in localHookParseResults {
            guard hookParseResult.path != localPath,
                  let issue = hookParseResult.result.issue else { continue }
            issues.append(issue)
        }
        let localActions = localConfig.map { actionEntries(from: $0.actions, sourcePath: localPath) } ?? [:]
        let globalActions = globalConfig.map { actionEntries(from: $0.actions, sourcePath: globalConfigPath) } ?? [:]

        // Local config takes precedence
        if let localConfig {
            if let newWorkspaceActionID = localConfig.ui?.newWorkspace?.action {
                configuredNewWorkspaceActionID = newWorkspaceActionID
                configuredNewWorkspaceActionSourcePath = localPath
            }
            if let contextMenu = localConfig.ui?.newWorkspace?.contextMenu {
                configuredNewWorkspaceContextMenu = contextMenu
                configuredNewWorkspaceContextMenuSourcePath = localPath
            }
            if configuredNewWorkspaceActionID == nil,
               let newWorkspaceCommand = localConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = newWorkspaceCommand
                configuredNewWorkspaceCommandSourcePath = localPath
            }
            if let buttons = localConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = buttons
                configuredSurfaceTabBarButtonSourcePath = localPath
            }
            for command in localConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                    if let localPath {
                        sourcePaths[command.id] = localPath
                    }
                }
            }
        }

        // Global config fills in the rest
        if let globalConfig {
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceActionID = globalConfig.ui?.newWorkspace?.action {
                configuredNewWorkspaceActionID = newWorkspaceActionID
                configuredNewWorkspaceActionSourcePath = globalConfigPath
            }
            if configuredNewWorkspaceContextMenu == nil,
               let contextMenu = globalConfig.ui?.newWorkspace?.contextMenu {
                configuredNewWorkspaceContextMenu = contextMenu
                configuredNewWorkspaceContextMenuSourcePath = globalConfigPath
            }
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceCommand = globalConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = newWorkspaceCommand
                configuredNewWorkspaceCommandSourcePath = globalConfigPath
            }
            if configuredSurfaceTabBarButtons == nil,
               let buttons = globalConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = buttons
                configuredSurfaceTabBarButtonSourcePath = globalConfigPath
            }
            for command in globalConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                    sourcePaths[command.id] = globalConfigPath
                }
            }
        }

        let resolvedActions = resolvedActionRegistry(
            globalActions: globalActions,
            localActions: localActions,
            commands: commands,
            commandSourcePaths: sourcePaths
        )
        let resolvedActionLookup = Dictionary(uniqueKeysWithValues: resolvedActions.map { ($0.id, $0) })
        let configuredButtons = configuredSurfaceTabBarButtons ?? CmuxSurfaceTabBarButton.defaults
        let defaultResolvedButtons = (try? CmuxSurfaceTabBarButton.defaults.map {
            try $0.resolved(actions: resolvedActionLookup, codingPath: [])
        }) ?? [
            .builtIn(.newTerminal),
            .builtIn(.newBrowser),
            .builtIn(.splitRight),
            .builtIn(.splitDown)
        ]
        let resolvedButtons = resolvedSurfaceTabBarButtons(
            configuredButtons,
            actions: resolvedActionLookup,
            settingName: "ui.surfaceTabBar.buttons"
        ) ?? ResolvedSurfaceTabBarButtons(
            buttons: defaultResolvedButtons,
            terminalCommandSourcePaths: [:]
        )
        let resolvedWorkspaceButtons = resolvedSurfaceTabBarWorkspaceCommands(
            resolvedButtons.buttons,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNewWorkspaceAction = resolvedConfiguredNewWorkspaceAction(
            actionID: configuredNewWorkspaceActionID,
            actionSourcePath: configuredNewWorkspaceActionSourcePath,
            commandName: configuredNewWorkspaceCommandName,
            commandSourcePath: configuredNewWorkspaceCommandSourcePath,
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNewWorkspaceContextMenuItems = resolvedConfigContextMenuItems(
            configuredNewWorkspaceContextMenu ?? Self.defaultNewWorkspaceContextMenu,
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths,
            settingName: "ui.newWorkspace.contextMenu",
            settingSourcePath: configuredNewWorkspaceContextMenuSourcePath
        )
        let resolvedNotificationHooks = resolveNotificationHooks(
            globalConfig: globalConfig,
            localConfigs: localHookParseResults.compactMap { entry in
                entry.result.config.map { (path: entry.path, config: $0) }
            }
        )

        loadedCommands = commands
        loadedActions = resolvedActions
        commandSourcePaths = sourcePaths
        actionLookup = resolvedActionLookup
        newWorkspaceActionID = configuredNewWorkspaceActionID
        newWorkspaceCommandName = configuredNewWorkspaceCommandName
        newWorkspaceContextMenuItems = resolvedNewWorkspaceContextMenuItems.items
        let resolvedGroupConfigs = resolveWorkspaceGroupConfigsFromLayers(
            localConfig: localConfig,
            globalConfig: globalConfig,
            localPath: localPath,
            globalPath: globalConfigPath,
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths,
            issues: &issues
        )
        workspaceGroupConfigs = resolvedGroupConfigs
        surfaceTabBarButtonSourcePath = configuredSurfaceTabBarButtonSourcePath
        surfaceTabBarCommandSourcePaths = resolvedButtons.terminalCommandSourcePaths
        surfaceTabBarWorkspaceCommands = resolvedWorkspaceButtons.workspaceCommands
        surfaceTabBarButtons = resolvedWorkspaceButtons.buttons
        notificationHooks = resolvedNotificationHooks
        resolvedNewWorkspaceActionCache = resolvedNewWorkspaceAction.action
        resolvedNewWorkspaceCommandCache = resolvedNewWorkspaceAction.command
        if let issue = resolvedNewWorkspaceAction.issue {
            issues.append(issue)
        }
        issues.append(contentsOf: resolvedNewWorkspaceContextMenuItems.issues)
        configurationIssues = issues
        if fileWatchingEnabled {
            updateLocalHookFileWatchers(
                paths: localHookPaths,
                primaryLocalPath: localPath
            )
        }
        applySurfaceTabBarButtonsToCurrentManager()
        configRevision &+= 1
    }

}
