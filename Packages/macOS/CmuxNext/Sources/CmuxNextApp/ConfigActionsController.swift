import CmuxNextActions
import CmuxNextSettings
import Observation

/// Registers the command `actions` from cmux.json (and inline command
/// entries of `ui.surfaceTabBar.buttons`) in the registry as
/// `cmuxConfig.<name>`, live: the settings watcher reloads the snapshot.
/// The palette, shortcuts and the CLI run them. The tab strip draws no
/// buttons for them (TAB-STRIP-TRAILING-BUTTONS-REMOVED).
final class ConfigActionsController {
    private let context: AppActionContext
    private var registeredCommands: [ConfigCommandAction] = []
    private var task: Task<Void, Never>?

    init(context: AppActionContext) {
        self.context = context
    }

    private var registry: ActionRegistry { context.registry }

    /// Applies the current snapshot now, then follows cmux.json changes.
    func start(settings: SettingsController) {
        guard task == nil else { return }
        apply(settings.snapshot.commandActions)
        // task-owner: this controller (cancelled in stop); event-driven (Observation).
        task = Task { [weak self] in
            for await commands in Observations({ settings.snapshot.commandActions }) {
                self?.apply(commands)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Replaces the registry's `cmuxConfig.*` actions with `commands`.
    func apply(_ commands: [ConfigCommandAction]) {
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
