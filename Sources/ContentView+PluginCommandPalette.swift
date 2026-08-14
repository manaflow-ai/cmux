import CmuxCommandPalette
import CmuxExtensionKit
import Foundation

extension ContentView {
    /// Contributions are projected from the same effective grant used by the
    /// socket path. A live action receiver is required so the palette never
    /// advertises a command whose process cannot currently consume it.
    func pluginCommandPaletteContributions() -> [CommandPaletteCommandContribution] {
        var contributions: [CommandPaletteCommandContribution] = []
        let snapshot = CmuxPluginRuntime.shared.currentSnapshot()
        for descriptor in snapshot.plugins where descriptor.isEnabled {
            guard descriptor.permissions.pluginScopes.contains(.paletteActions) else { continue }
            let pluginID = descriptor.plugin.manifest.id
            guard CmuxPluginRuntime.shared.canReceiveActionInvocations(pluginID: pluginID) else {
                continue
            }
            let pluginName = sanitizeCmuxConfigPaletteText(descriptor.plugin.manifest.displayName)
            let fallbackSubtitle = String(
                format: String(
                    localized: "commandPalette.subtitle.plugin",
                    defaultValue: "Plugin • %@"
                ),
                pluginName
            )
            for action in descriptor.plugin.manifest.actions
                where descriptor.permissions.allowsAction(action.id) {
                let commandID = CmuxPluginRegistry.namespacedActionID(
                    pluginID: pluginID,
                    actionID: action.id
                )
                let title = sanitizeCmuxConfigPaletteText(action.title)
                let subtitle = action.subtitle
                    .map(sanitizeCmuxConfigPaletteText)
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? fallbackSubtitle
                contributions.append(CommandPaletteCommandContribution(
                    commandId: commandID,
                    title: { _ in title },
                    subtitle: { _ in subtitle },
                    shortcutHint: CmuxPluginRuntime.shared
                        .routablePluginShortcutBindings()[commandID]?
                        .displayString,
                    keywords: action.keywords + [pluginName]
                ))
            }
        }
        return contributions
    }

    func registerPluginCommandPaletteHandlers(
        _ registry: inout CommandPaletteHandlerRegistry
    ) {
        let snapshot = CmuxPluginRuntime.shared.currentSnapshot()
        for descriptor in snapshot.plugins where descriptor.isEnabled {
            guard descriptor.permissions.pluginScopes.contains(.paletteActions) else { continue }
            let pluginID = descriptor.plugin.manifest.id
            guard CmuxPluginRuntime.shared.canReceiveActionInvocations(pluginID: pluginID) else {
                continue
            }
            for action in descriptor.plugin.manifest.actions
                where descriptor.permissions.allowsAction(action.id) {
                let commandID = CmuxPluginRegistry.namespacedActionID(
                    pluginID: pluginID,
                    actionID: action.id
                )
                registry.register(commandId: commandID) {
                    _ = CmuxPluginRuntime.shared.invokeAction(
                        pluginID: pluginID,
                        actionID: action.id
                    )
                }
            }
        }
    }
}
