import AppKit
import CmuxExtensionKit

extension AppDelegate {
    func configuredPluginShortcutBindings() -> [StoredShortcut] {
        guard let pluginRuntime else { return [] }
        return Array(pluginRuntime.routablePluginShortcutBindings().values)
    }

    @discardableResult
    func handlePluginShortcut(event: NSEvent) -> Bool {
        guard let pluginRuntime else { return false }
        let routableBindings = pluginRuntime.routablePluginShortcutBindings()
        for (commandID, shortcut) in routableBindings {
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
