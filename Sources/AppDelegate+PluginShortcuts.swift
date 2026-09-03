import AppKit
import CmuxExtensionKit

extension AppDelegate {
    /// Returns user-defined cmux shortcuts so plugin conflict checks match the
    /// configured-action routing that runs before plugin shortcuts.
    func configuredCmuxShortcutBindingsForPluginConflicts() -> [String: StoredShortcut] {
        var bindings: [String: StoredShortcut] = [:]
        for context in mainWindowContexts.values {
            for action in context.cmuxConfigStore?.shortcutActions() ?? [] {
                if let shortcut = action.shortcut {
                    bindings[action.id] = shortcut
                }
            }
        }
        return bindings
    }

    func refreshConfiguredCmuxShortcutBindingsForPlugins() {
        pluginRuntime?.setConfiguredCmuxShortcutBindings(
            configuredCmuxShortcutBindingsForPluginConflicts()
        )
    }

    func configuredPluginShortcutBindings(for event: NSEvent) -> [StoredShortcut] {
        guard let pluginRuntime else { return [] }
        return pluginRuntime.routablePluginChordShortcuts(for: event)
    }

    @discardableResult
    func handlePluginShortcut(event: NSEvent) -> Bool {
        guard let pluginRuntime else { return false }
        let commandIDs = pluginRuntime.routablePluginShortcutActionIDs(
            for: event,
            completingChord: activeConfiguredShortcutChordPrefixForCurrentEvent != nil
        )
        for commandID in commandIDs {
            guard let shortcut = pluginRuntime.routablePluginShortcut(for: commandID) else {
                continue
            }
            guard matchConfiguredShortcut(event: event, shortcut: shortcut) else {
                continue
            }
            if let resolved = pluginRuntime.action(forNamespacedID: commandID) {
                _ = pluginRuntime.invokeAction(
                    pluginID: resolved.pluginID,
                    actionID: resolved.action.id
                )
            }
            // The shortcut matched a plugin binding. Consume it even if the
            // action disappeared during reload; otherwise the keystroke can
            // fall through into terminal input.
            return true
        }
        return false
    }
}
