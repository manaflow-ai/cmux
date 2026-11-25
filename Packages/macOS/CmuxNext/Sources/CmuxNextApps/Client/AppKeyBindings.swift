public import CmuxNextActions
import CmuxNextCompat
import CmuxNextSettings
import os

/// The binding table's app layer: each visible app's command shortcuts
/// (catalog `keyboard` chords, apps-list `commands[].keys`) as
/// `app.command.run` entries, so a Cmd or Ctrl chord an extension asks for
/// runs its command the way its palette row does. They sit above cmux's
/// defaults and below the user's keybindings.json, whose removals
/// (`-app.command.run`) take them out. A hidden or disabled app contributes
/// none (the presence rule, D55). Single page keys (`f` on a browser page)
/// are not here: the daemon sends those as `page_keys`.
@MainActor
public final class AppKeyBindings {
    /// The entries last loaded.
    public private(set) var loaded: [KeyBinding] = []
    private var watch: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "apps.keys")

    init(client: AppsClient, registry: ActionRegistry) {
        // task-owner: the client lives as long as the app; one watch of its apps' shortcuts.
        watch = Task { [weak self, weak client, weak registry] in
            for await next in ObservationStream({ [weak client] in Self.bindings(client?.apps ?? []) }) {
                guard let self, let registry else { return }
                self.loaded = next
                for issue in KeyBindingLoader(registry).loadApp(next) {
                    Self.logger.error("app shortcut \(issue.index, privacy: .public) left out: \(String(describing: issue.kind), privacy: .public)")
                }
            }
        }
    }

    /// The app layer for `apps` (pure, for tests): visible apps only, in list
    /// order; a key that is not one chord or a `when` that does not parse is skipped.
    public static func bindings(_ apps: [AppRecord]) -> [KeyBinding] {
        apps.filter(\.isVisible).flatMap { app in
            app.commands.flatMap { command in
                command.keys.compactMap { key -> KeyBinding? in
                    guard let stroke = ShortcutBindingFormat.parseStroke(key.key) else { return nil }
                    var when: WhenClause?
                    if let text = key.when {
                        guard let clause = try? WhenClause.parse(text) else { return nil }
                        when = clause
                    }
                    return KeyBinding(keys: [SettingsApplier.shortcut(for: stroke)], command: "app.command.run",
                                      arguments: ["app": .string(app.id), "command": .string(command.op)], when: when, source: .app)
                }
            }
        }
    }
}

extension AppsClient {
    /// Keeps `registry`'s app layer equal to the visible apps' command shortcuts from now on.
    public func followKeyBindings(in registry: ActionRegistry) {
        keyBindings = AppKeyBindings(client: self, registry: registry)
    }
}
