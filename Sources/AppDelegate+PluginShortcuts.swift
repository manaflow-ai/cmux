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
            return pluginRuntime.invokeAction(
                pluginID: resolved.pluginID,
                actionID: resolved.action.id
            )
        }
        return false
    }
}
