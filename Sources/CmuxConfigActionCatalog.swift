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

    /// Composes user palette actions with cmux-owned action IDs. Exact ID
    /// conflicts become visible configuration issues; non-colliding
    /// `palette.*` IDs remain valid stable user IDs.
    func composingPaletteActions(
        reservedActionIDs: Set<String>,
        diagnosticActionID: (CmuxConfigIssue) -> String
    ) -> (issues: [CmuxConfigIssue], actions: [CmuxResolvedConfigAction]) {
        let configuredActions = paletteCustomActions()
        let baseIssues = configurationIssues
        var collidingActionIDs = Set(
            configuredActions.lazy.map(\.id).filter(reservedActionIDs.contains)
        )
        var issues = baseIssues

        // Diagnostics are themselves command-palette actions. Iterate to a
        // fixed point so their generated IDs cannot silently collide either.
        while true {
            issues = baseIssues + configuredActions.compactMap { action in
                guard collidingActionIDs.contains(action.id) else { return nil }
                return CmuxConfigIssue(
                    kind: .paletteActionIDCollision,
                    settingName: "actions",
                    commandName: action.id,
                    sourcePath: action.actionSourcePath
                )
            }
            let diagnosticIDs = Set(issues.map(diagnosticActionID))
            let nextCollidingIDs = Set(configuredActions.lazy.map(\.id).filter {
                reservedActionIDs.contains($0) || diagnosticIDs.contains($0)
            })
            guard nextCollidingIDs != collidingActionIDs else { break }
            collidingActionIDs = nextCollidingIDs
        }

        return (
            issues,
            configuredActions.filter { !collidingActionIDs.contains($0.id) }
        )
    }
}
