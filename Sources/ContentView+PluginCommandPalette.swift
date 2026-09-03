import CmuxCommandPalette
import CmuxExtensionKit
import Foundation

extension ContentView {
    private typealias AuthorizedPluginAction = (
        pluginID: String,
        pluginName: String,
        action: CmuxExtensionAction,
        commandID: String
    )

    /// Contributions are projected from the same effective grant used by the
    /// socket path. A live action receiver is required so the palette never
    /// advertises a command whose process cannot currently consume it.
    func pluginCommandPaletteContributions() -> [CommandPaletteCommandContribution] {
        guard let pluginRuntime else { return [] }
        var contributions: [CommandPaletteCommandContribution] = []
        let shortcutBindings = pluginRuntime.routablePluginShortcutBindings()
        for declaration in authorizedPluginActions(runtime: pluginRuntime) {
            let pluginName = sanitizeCmuxConfigPaletteText(declaration.pluginName)
            let fallbackSubtitle = String.localizedStringWithFormat(
                String(
                    localized: "commandPalette.subtitle.plugin",
                    defaultValue: "Plugin • %@"
                ),
                pluginName
            )
            let title = sanitizeCmuxConfigPaletteText(declaration.action.title)
            let subtitle = declaration.action.subtitle
                .map(sanitizeCmuxConfigPaletteText)
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? fallbackSubtitle
            contributions.append(CommandPaletteCommandContribution(
                commandId: declaration.commandID,
                title: { _ in title },
                subtitle: { _ in subtitle },
                shortcutHint: shortcutBindings[declaration.commandID]?.displayString,
                keywords: declaration.action.keywords + [pluginName]
            ))
        }
        return contributions
    }

    func registerPluginCommandPaletteHandlers(
        _ registry: inout CommandPaletteHandlerRegistry
    ) {
        guard let pluginRuntime else { return }
        for declaration in authorizedPluginActions(runtime: pluginRuntime) {
            registry.register(commandId: declaration.commandID) {
                _ = pluginRuntime.invokeAction(
                    pluginID: declaration.pluginID,
                    actionID: declaration.action.id
                )
            }
        }
    }

    private func authorizedPluginActions(
        runtime: CmuxPluginRuntime
    ) -> [AuthorizedPluginAction] {
        let snapshot = runtime.currentSnapshot()
        return snapshot.plugins.flatMap { descriptor -> [AuthorizedPluginAction] in
            let pluginID = descriptor.plugin.manifest.id
            guard descriptor.isEnabled,
                  descriptor.permissions.pluginScopes.contains(.paletteActions),
                  runtime.canReceiveActionInvocations(pluginID: pluginID) else {
                return []
            }
            return descriptor.plugin.manifest.actions.compactMap {
                action -> AuthorizedPluginAction? in
                guard descriptor.permissions.allowsAction(action.id) else { return nil }
                return (
                    pluginID: pluginID,
                    pluginName: descriptor.plugin.manifest.displayName,
                    action: action,
                    commandID: CmuxPluginRegistry.namespacedActionID(
                        pluginID: pluginID,
                        actionID: action.id
                    )
                )
            }
        }
    }
}
