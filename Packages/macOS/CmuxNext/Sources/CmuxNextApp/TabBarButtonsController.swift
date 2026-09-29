import CmuxNextActions
import CmuxNextSettings
import CmuxNextTabs
import Observation
import os

/// Owns the trailing tab-strip buttons for every pane. Reads
/// `ui.surfaceTabBar.buttons` and the command `actions` from cmux.json
/// (live: the settings watcher reloads the snapshot), registers each command
/// action in the registry as `cmuxConfig.<name>`, and resolves buttons with
/// live shortcut tooltips. A click runs the button's registry action
/// targeted at the clicked pane, the same path as the palette and the CLI.
@Observable
final class TabBarButtonsController {
    private(set) var buttons: [TabStripButton] = []
    @ObservationIgnored private(set) var actions: [String: ActionID] = [:]
    @ObservationIgnored private let context: AppActionContext
    @ObservationIgnored private var specs: [TabBarButtonSpec] = SurfaceTabBarConfig.defaultButtons
    @ObservationIgnored private var registeredCommands: [ConfigCommandAction] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var reportedUnknown: Set<String> = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.tabbar")

    init(context: AppActionContext) {
        self.context = context
        refresh()
    }

    private var registry: ActionRegistry { context.registry }

    /// Applies the current snapshot now, then follows cmux.json and shortcut changes.
    func start(settings: SettingsController) {
        guard tasks.isEmpty else { return }
        apply(settings.snapshot)
        tasks.append(Task { [weak self] in
            for await input in Observations({ Input(tabBar: settings.snapshot.tabBar, commands: settings.snapshot.commandActions) }) {
                self?.apply(input)
            }
        })
        // Shortcut rebinds change tooltips.
        let registry = registry
        tasks.append(Task { [weak self] in
            for await _ in Observations({ registry.shortcutOverrides.count + registry.actions.count }) {
                self?.refresh()
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    struct Input: Equatable, Sendable {
        var tabBar: SurfaceTabBarConfig
        var commands: [ConfigCommandAction]
    }

    func apply(_ snapshot: CmuxConfigSnapshot) {
        apply(Input(tabBar: snapshot.tabBar, commands: snapshot.commandActions))
    }

    func apply(_ input: Input) {
        registerCommands(input.commands)
        specs = input.tabBar.buttons
        refresh()
    }

    /// Runs button `id` for the pane `paneKey`. Returns whether it ran.
    @discardableResult
    func perform(_ id: String, paneKey: String) -> Bool {
        guard let action = actions[id] else { return false }
        return registry.perform(action, invocation: ActionInvocation(target: ActionTargetRef(kind: .pane, id: paneKey)))
    }

    private func refresh() {
        let resolved = TabBarButtonResolver.resolve(specs, registry: registry)
        for spec in resolved.unknown where reportedUnknown.insert(spec.actionID).inserted {
            logger.notice("tab bar button \(spec.id, privacy: .public): no action \(spec.actionID, privacy: .public)")
        }
        actions = resolved.actions
        if buttons != resolved.buttons { buttons = resolved.buttons }
    }

    /// Replaces the registry's `cmuxConfig.*` actions with `commands`.
    private func registerCommands(_ commands: [ConfigCommandAction]) {
        guard commands != registeredCommands else { return }
        let keep = Set(commands.map(\.actionID))
        for old in registeredCommands where !keep.contains(old.actionID) {
            registry.unbind(ActionID(rawValue: old.actionID))
        }
        for command in commands {
            let context = context
            registry.register(Action(
                id: ActionID(rawValue: command.actionID),
                title: command.title,
                keywords: [command.name, command.command],
                invoke: { ConfigCommandRunner.run(command, invocation: $0, context: context) },
                handler: {}
            ))
        }
        registeredCommands = commands
    }
}
