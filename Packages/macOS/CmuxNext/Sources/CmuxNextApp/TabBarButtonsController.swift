import AppKit
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
/// Without a cmux.json list, each pane shows the default buttons for its
/// selected tab's kind; a list longer than ``PaneToolbar/maxVisibleButtons``
/// ends in "..." (``PaneToolbar``).
@Observable
final class TabBarButtonsController {
    /// The cmux.json list (empty while it sets none).
    private(set) var buttons: [TabStripButton] = []
    /// The default buttons by kind, while cmux.json sets no list.
    private(set) var defaultButtons: [PaneToolbar.Kind: [TabStripButton]] = [:]
    private(set) var usesDefaults = true
    @ObservationIgnored private(set) var actions: [String: ActionID] = [:]
    @ObservationIgnored private let context: AppActionContext
    @ObservationIgnored private lazy var overflowTarget = OverflowMenuTarget(controller: self)
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
            for await _ in Observations({ [registry.shortcutOverrides.count, registry.chordOverrides.count, registry.actions.count] }) {
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
        if usesDefaults != input.tabBar.usesDefaults { usesDefaults = input.tabBar.usesDefaults }
        refresh()
    }

    /// Every button of a pane whose selected tab is of `kind`, before compacting.
    func allButtons(for kind: PaneToolbar.Kind) -> [TabStripButton] {
        usesDefaults ? defaultButtons[kind] ?? [] : buttons
    }

    /// The strip buttons of a pane whose selected tab is of `kind`.
    func buttons(for kind: PaneToolbar.Kind) -> [TabStripButton] {
        PaneToolbar.visible(allButtons(for: kind))
    }

    /// "..."'s menu on pane `paneKey`: one row per button that did not fit,
    /// under the button's label and with its action's shortcut. Choosing a
    /// row runs the button on the pane (`perform`), as clicking it would.
    func overflowMenu(for kind: PaneToolbar.Kind, paneKey: String) -> NSMenu {
        let menu = NSMenu()
        for button in PaneToolbar.overflow(allButtons(for: kind)) {
            guard let action = actions[button.id] else { continue }
            let item = registry.makeMenuItem(for: action) ?? NSMenuItem()
            item.title = button.accessibilityLabel
            item.target = overflowTarget
            item.action = #selector(OverflowMenuTarget.run(_:))
            item.representedObject = OverflowMenuTarget.Row(buttonID: button.id, paneKey: paneKey)
            menu.addItem(item)
        }
        return menu
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
        guard usesDefaults else {
            if !defaultButtons.isEmpty { defaultButtons = [:] }
            return
        }
        var defaults: [PaneToolbar.Kind: [TabStripButton]] = [:]
        for kind in PaneToolbar.Kind.allCases {
            let resolvedDefaults = TabBarButtonResolver.resolve(PaneToolbar.defaultSpecs(for: kind), registry: registry)
            defaults[kind] = resolvedDefaults.buttons
            actions.merge(resolvedDefaults.actions) { current, _ in current }
        }
        if defaultButtons != defaults { defaultButtons = defaults }
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

/// Runs a "..." row: the overflowed button on its pane.
final class OverflowMenuTarget: NSObject {
    final class Row: NSObject {
        let buttonID: String
        let paneKey: String

        init(buttonID: String, paneKey: String) {
            self.buttonID = buttonID
            self.paneKey = paneKey
        }
    }

    private weak var controller: TabBarButtonsController?

    init(controller: TabBarButtonsController) {
        self.controller = controller
    }

    @objc func run(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row else { return }
        controller?.perform(row.buttonID, paneKey: row.paneKey)
    }
}
