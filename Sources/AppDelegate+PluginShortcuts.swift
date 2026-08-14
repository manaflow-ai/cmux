import AppKit
import CmuxExtensionKit

extension AppDelegate {
    func configuredPluginShortcutBindings() -> [StoredShortcut] {
        Array(CmuxPluginRuntime.shared.routablePluginShortcutBindings().values)
    }

    @discardableResult
    func handlePluginShortcut(event: NSEvent) -> Bool {
        let routableBindings = CmuxPluginRuntime.shared.routablePluginShortcutBindings()
        for (commandID, shortcut) in routableBindings {
            guard matchConfiguredShortcut(event: event, shortcut: shortcut),
                  let resolved = CmuxPluginRuntime.shared.action(forNamespacedID: commandID) else {
                continue
            }
            return CmuxPluginRuntime.shared.invokeAction(
                pluginID: resolved.pluginID,
                actionID: resolved.action.id
            )
        }
        return false
    }
}
