/// Immutable action/command resolution for one configuration directory.
///
/// Command-palette automation captures this value alongside its immutable
/// window/workspace/panel target. Resolving a background workspace therefore
/// never changes the selected workspace or the store's published live config.
struct CmuxConfigActionCatalog: Sendable {
    let loadedCommands: [CmuxCommandDefinition]
    let loadedActions: [CmuxResolvedConfigAction]
    let commandSourcePaths: [String: String]
    let configurationIssues: [CmuxConfigIssue]
    let resolvedNewWorkspaceAction: CmuxResolvedConfigAction?
    let resolvedNewWorkspaceCommand: CmuxResolvedCommand?

    let configuredNewWorkspaceActionID: String?
    let configuredNewWorkspaceActionSourcePath: String?
    let configuredNewWorkspaceCommandName: String?
    let configuredNewWorkspaceCommandSourcePath: String?

    private let actionLookup: [String: CmuxResolvedConfigAction]

    init(
        loadedCommands: [CmuxCommandDefinition],
        loadedActions: [CmuxResolvedConfigAction],
        commandSourcePaths: [String: String],
        configurationIssues: [CmuxConfigIssue],
        resolvedNewWorkspaceAction: CmuxResolvedConfigAction?,
        resolvedNewWorkspaceCommand: CmuxResolvedCommand?,
        configuredNewWorkspaceActionID: String?,
        configuredNewWorkspaceActionSourcePath: String?,
        configuredNewWorkspaceCommandName: String?,
        configuredNewWorkspaceCommandSourcePath: String?
    ) {
        self.loadedCommands = loadedCommands
        self.loadedActions = loadedActions
        self.commandSourcePaths = commandSourcePaths
        self.configurationIssues = configurationIssues
        self.resolvedNewWorkspaceAction = resolvedNewWorkspaceAction
        self.resolvedNewWorkspaceCommand = resolvedNewWorkspaceCommand
        self.configuredNewWorkspaceActionID = configuredNewWorkspaceActionID
        self.configuredNewWorkspaceActionSourcePath = configuredNewWorkspaceActionSourcePath
        self.configuredNewWorkspaceCommandName = configuredNewWorkspaceCommandName
        self.configuredNewWorkspaceCommandSourcePath = configuredNewWorkspaceCommandSourcePath
        self.actionLookup = Dictionary(uniqueKeysWithValues: loadedActions.map { ($0.id, $0) })
    }

    func resolvedAction(id: String) -> CmuxResolvedConfigAction? {
        let canonicalID = CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
        return actionLookup[canonicalID]
    }

    func paletteCustomActions() -> [CmuxResolvedConfigAction] {
        let builtInIDs = Set(CmuxSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.palette && !builtInIDs.contains(action.id)
        }
    }

    /// Composes user palette actions with cmux-owned action IDs and namespaces.
    /// Conflicts become visible configuration issues; non-colliding
    /// `palette.*` IDs remain valid stable user IDs.
    func composingPaletteActions(
        reservedActionIDs: Set<String>,
        reservedActionIDPrefixes: [String] = []
    ) -> (issues: [CmuxConfigIssue], actions: [CmuxResolvedConfigAction]) {
        let configuredActions = paletteCustomActions()
        var issues = configurationIssues
        var actions: [CmuxResolvedConfigAction] = []
        actions.reserveCapacity(configuredActions.count)

        for action in configuredActions {
            let collidesWithReservedID = reservedActionIDs.contains(action.id)
            let collidesWithReservedNamespace = reservedActionIDPrefixes.contains {
                action.id.hasPrefix($0)
            }
            if collidesWithReservedID || collidesWithReservedNamespace {
                issues.append(
                    CmuxConfigIssue(
                        kind: .paletteActionIDCollision,
                        settingName: "actions",
                        commandName: action.id,
                        sourcePath: action.actionSourcePath
                    )
                )
            } else {
                actions.append(action)
            }
        }

        return (issues, actions)
    }
}
