public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextSettings
import Observation

/// Registers the command `actions` from cmux.json (and inline command
/// entries of `ui.surfaceTabBar.buttons`) in the registry as
/// `cmuxConfig.<name>`, live: the settings watcher reloads the snapshot.
/// The palette, shortcuts and the CLI run them. The tab strip draws no
/// buttons for them (TAB-STRIP-TRAILING-BUTTONS-REMOVED).
@MainActor
public final class ConfigActionsController {
    private var commands: CommandActionSet
    private var task: Task<Void, Never>?

    /// - Parameter run: Runs a picked command (the App's `ConfigCommandRunner`).
    public init(registry: ActionRegistry, run: @escaping @MainActor (ConfigCommandAction, ActionInvocation) -> Void) {
        self.commands = CommandActionSet(registry: registry, run: run)
    }

    /// Applies the current snapshot now, then follows cmux.json changes.
    public func start(settings: SettingsController) {
        guard task == nil else { return }
        apply(settings.snapshot.commandActions)
        // task-owner: this controller (cancelled in stop); event-driven (Observation).
        task = Task { [weak self] in
            for await commands in ObservationStream({ settings.snapshot.commandActions }) {
                self?.apply(commands)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Replaces the registry's `cmuxConfig.*` actions with `commands`.
    public func apply(_ commands: [ConfigCommandAction]) {
        self.commands.apply(commands)
    }
}

/// Commands registered as actions under their `actionID`s: a new list replaces the last one,
/// unbinding the ids it no longer has.
@MainActor
struct CommandActionSet {
    let registry: ActionRegistry
    let run: @MainActor (ConfigCommandAction, ActionInvocation) -> Void
    private(set) var registered: [ConfigCommandAction] = []

    init(registry: ActionRegistry, run: @escaping @MainActor (ConfigCommandAction, ActionInvocation) -> Void) {
        self.registry = registry
        self.run = run
    }

    mutating func apply(_ commands: [ConfigCommandAction], keywords extra: [String] = []) {
        guard commands != registered else { return }
        let keep = Set(commands.map(\.actionID))
        for old in registered where !keep.contains(old.actionID) {
            registry.unbind(ActionID(rawValue: old.actionID))
        }
        for command in commands {
            let run = run
            registry.register(Action(
                id: ActionID(rawValue: command.actionID),
                title: command.title,
                keywords: [command.name, command.command] + extra,
                invoke: { run(command, $0) },
                handler: {}
            ))
        }
        registered = commands
    }
}
