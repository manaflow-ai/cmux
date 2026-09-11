import CmuxCommandPalette
import CmuxExtensionKit
import Foundation
import SwiftUI

extension ContentView {
    func pluginAndConfigPaletteContributions(
        defaultSubtitle: String
    ) -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String { { _ in value } }
        var contributions: [CommandPaletteCommandContribution] = []
        let pluginContributions = pluginCommandPaletteContributions()
        let activePluginCommandIDs = Set(pluginContributions.map(\.commandId))
        for action in cmuxConfigStore.paletteCustomActions() {
            guard !activePluginCommandIDs.contains(action.id) else { continue }
            let actionTitle = sanitizeCmuxConfigPaletteText(action.title)
            let subtitleText = action.subtitle
                .map { sanitizeCmuxConfigPaletteText($0) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? defaultSubtitle
            contributions.append(CommandPaletteCommandContribution(
                commandId: action.id,
                title: constant(actionTitle),
                subtitle: constant(subtitleText),
                keywords: action.keywords
            ))
        }
        contributions.append(contentsOf: pluginContributions)
        return contributions
    }

    func registerPluginAndConfiguredCommandPaletteHandlers(
        _ registry: inout CommandPaletteHandlerRegistry
    ) {
        for issue in cmuxConfigStore.configurationIssues {
            let captured = issue
            registry.register(commandId: commandPaletteCmuxConfigIssueCommandID(issue)) {
                openCmuxConfigIssue(captured)
            }
        }
        let activePluginCommandIDs = Set(pluginCommandPaletteContributions().map(\.commandId))
        for action in cmuxConfigStore.paletteCustomActions() {
            guard !activePluginCommandIDs.contains(action.id) else { continue }
            let captured = action
            registry.register(commandId: action.id) { executeConfiguredAction(captured) }
        }
        registerPluginCommandPaletteHandlers(&registry)
    }

    func applyingPluginChangeObservers(to view: AnyView) -> AnyView {
        AnyView(view
            .task {
                for await _ in NotificationCenter.default.notifications(named: .cmuxPluginManagementDidChange) {
                    guard !Task.isCancelled else { return }
                    pluginSnapshotRevision &+= 1
                    commandPaletteResultsRevision &+= 1
                }
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: .cmuxPluginShortcutsDidChange) {
                    guard !Task.isCancelled else { return }
                    commandPaletteResultsRevision &+= 1
                    scheduleCommandPaletteResultsRefresh(query: commandPaletteQuery, forceSearchCorpusRefresh: true, preservePendingActivation: true)
                }
            })
    }

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
