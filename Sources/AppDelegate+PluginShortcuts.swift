import AppKit
import CmuxExtensionKit

extension AppDelegate {
    func configuredPluginShortcutBindings() -> [StoredShortcut] {
        Array(pluginRuntime.routablePluginShortcutBindings().values)
    }

    @discardableResult
    func handlePluginShortcut(event: NSEvent) -> Bool {
        let routableBindings = pluginRuntime.routablePluginShortcutBindings()
        for (commandID, shortcut) in routableBindings {
            guard matchConfiguredShortcut(event: event, shortcut: shortcut),
                  let resolved = pluginRuntime.action(forNamespacedID: commandID) else {
                continue
            }
            _ = pluginRuntime.invokeAction(
                pluginID: resolved.pluginID,
                actionID: resolved.action.id
            )
            // The shortcut matched and resolved to a plugin action. Consume it
            // even if the plugin is disabled between resolution and delivery;
            // otherwise the keystroke can fall through into terminal input.
            return true
        }
        return false
    }
}
