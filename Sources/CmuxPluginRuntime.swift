import CmuxFoundation
import CmuxSettings
import Foundation

/// Connects enabled extension plugins (`cmux-plugin.toml`, `kind = "extension"`)
/// to the existing action registry and automation engine.
///
/// Plugin `[[actions]]` become `plugin.<name>.<action>` entries in the cmux.json
/// action registry, so the command palette, shortcuts, and tab-bar buttons
/// treat them like any other action. Plugin `[[events]]` become `run` rules in
/// the automation engine, which already owns process groups and timeouts.
/// Nothing is loaded for a plugin until the user enables it.
@MainActor
final class CmuxPluginRuntime {
    static let shared = CmuxPluginRuntime()

    static let defaultTimeoutSeconds = 60
    static let actionIcon = CmuxButtonIcon.symbol("puzzlepiece.extension")

    let paths: CmuxPluginPaths
    private(set) var catalog: CmuxPluginCatalog

    init(paths: CmuxPluginPaths = CmuxPluginPaths(), catalog: CmuxPluginCatalog? = nil) {
        self.paths = paths
        self.catalog = catalog ?? CmuxPluginCatalog.load(paths: paths)
        logProblems()
    }

    /// Rereads the install root and enablement file.
    func reload() {
        catalog = CmuxPluginCatalog.load(paths: paths)
        logProblems()
    }

    static func registryID(plugin: String, action: String) -> String {
        "plugin.\(plugin).\(action)"
    }

    // MARK: - Actions

    /// Registry entries for every action of every enabled plugin. A default
    /// shortcut is dropped when it is invalid or already bound to a cmux
    /// shortcut; users can still bind any key to the action in cmux.json.
    /// `reservedShortcuts` defaults to every current cmux shortcut.
    func configActions(reservedShortcuts: Set<StoredShortcut>? = nil) -> [CmuxResolvedConfigAction] {
        let active = catalog.activePlugins
        guard !active.isEmpty else { return [] }
        let needsReserved = active.contains { plugin in plugin.manifest.actions.contains { $0.shortcut != nil } }
        let reserved = needsReserved ? (reservedShortcuts ?? Self.cmuxShortcuts()) : []
        return active.flatMap { plugin in
            plugin.manifest.actions.map { action in
                let shortcut = action.shortcut
                    .flatMap { StoredShortcut.parseConfig($0) }
                    .flatMap { reserved.contains($0) ? nil : $0 }
                return CmuxResolvedConfigAction(
                    id: Self.registryID(plugin: plugin.name, action: action.id),
                    title: action.title,
                    subtitle: action.subtitle ?? plugin.name,
                    keywords: action.keywords + ["plugin", plugin.name],
                    palette: action.palette,
                    shortcut: shortcut,
                    icon: Self.actionIcon,
                    tooltip: action.title,
                    action: .plugin(Self.registryID(plugin: plugin.name, action: action.id)),
                    confirm: nil,
                    terminalCommandTarget: nil,
                    // Shortcut routing only honors non-built-in actions that
                    // have a source file; the manifest is that file.
                    actionSourcePath: plugin.manifestURL.path,
                    iconSourcePath: nil
                )
            }
        }
    }

    static func cmuxShortcuts() -> Set<StoredShortcut> {
        Set(KeyboardShortcutSettings.Action.allCases.map { KeyboardShortcutSettings.shortcut(for: $0) })
    }

    /// Runs an enabled plugin action with the given workspace and surface as
    /// context. Returns false when the action is unknown or its plugin is not
    /// enabled; the process itself runs in the background.
    @discardableResult
    func invoke(registryID: String, workspaceID: UUID?, surfaceID: UUID?) -> Bool {
        for plugin in catalog.activePlugins {
            for action in plugin.manifest.actions
            where Self.registryID(plugin: plugin.name, action: action.id) == registryID {
                var context = baseContext()
                context.actionID = registryID
                context.workspaceID = workspaceID?.uuidString
                context.surfaceID = surfaceID?.uuidString
                let invocation = CmuxPluginInvocation(plugin: plugin, argv: action.argv, context: context, paths: paths)
                let timeout = TimeInterval(action.timeoutSeconds ?? Self.defaultTimeoutSeconds)
                let session = AutomationProcessSession(command: invocation.shellScript, environment: [:])
                Task.detached(priority: .utility) {
                    let result = await session.run(timeoutSeconds: timeout)
                    if !result.succeeded {
                        NSLog("[CmuxPlugin] %@ failed: %@", registryID, result.detail)
                    }
                }
                return true
            }
        }
        return false
    }

    // MARK: - Events

    /// One automation `run` rule per `[[events]]` entry of every enabled plugin.
    /// Rule ids are `plugin.<name>.events.<index>`.
    func automationRules() -> [AutomationRule] {
        let context = baseContext()
        return catalog.activePlugins.flatMap { plugin in
            plugin.manifest.events.enumerated().map { index, hook in
                let invocation = CmuxPluginInvocation(plugin: plugin, argv: hook.argv, context: context, paths: paths)
                return AutomationRule(
                    id: "plugin.\(plugin.name).events.\(index)",
                    when: AutomationWhen(event: hook.event),
                    actions: [
                        AutomationAction(action: "run", parameters: [
                            "command": .string(invocation.shellScript),
                            "timeout_seconds": .integer(Int64(hook.timeoutSeconds ?? Self.defaultTimeoutSeconds)),
                        ]),
                    ]
                )
            }
        }
    }

    // MARK: - Private

    private func baseContext() -> CmuxPluginInvocationContext {
        let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux")
        let cliPath = cliURL.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0.path : nil }
        return CmuxPluginInvocationContext(
            socketPath: TerminalController.shared.activeSocketPath(preferredPath: SocketControlSettings.socketPath()),
            cliPath: cliPath
        )
    }

    private func logProblems() {
        for problem in catalog.problems {
            NSLog("[CmuxPlugin] skipped %@: %@", problem.name, problem.message)
        }
    }
}

extension TerminalController {
    /// `plugin.reload`: rereads installed plugins, then refreshes the action
    /// registry in every window and the automation rules.
    @MainActor
    func v2PluginReload() -> V2CallResult {
        let runtime = CmuxPluginRuntime.shared
        runtime.reload()
        AppDelegate.shared?.reloadableConfigStores.forEach { $0.loadAll() }
        automationEngine?.scheduleReload()
        return .ok([
            "active": runtime.catalog.activePlugins.map(\.name),
            "problems": runtime.catalog.problems.map { ["name": $0.name, "message": $0.message] },
        ])
    }

    /// `plugin.action.invoke`: runs `plugin.<name>.<action>` with the caller's
    /// workspace and surface (or the selected ones) as context.
    @MainActor
    func v2PluginActionInvoke(params: [String: Any]) -> V2CallResult {
        guard let id = v2String(params, "id"), !id.isEmpty else {
            return .err(
                code: "invalid_params",
                message: String(localized: "plugin.error.missingActionID", defaultValue: "Missing plugin action id"),
                data: nil
            )
        }
        let workspace = v2ResolveTabManager(params: params).flatMap { v2ResolveWorkspace(params: params, tabManager: $0) }
        let surfaceID = v2UUID(params, "surface_id") ?? workspace?.focusedPanelId
        guard CmuxPluginRuntime.shared.invoke(registryID: id, workspaceID: workspace?.id, surfaceID: surfaceID) else {
            return .err(
                code: "not_found",
                message: String(
                    format: String(
                        localized: "plugin.error.actionNotFound",
                        defaultValue: "No enabled plugin action named %@. Run cmux plugin list to see installed plugins."
                    ),
                    id
                ),
                data: nil
            )
        }
        return .ok(["id": id, "started": true])
    }
}
