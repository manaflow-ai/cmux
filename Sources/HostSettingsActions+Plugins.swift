import CmuxExtensionKit
import CmuxSettings
import CmuxSettingsUI
import Foundation

extension HostSettingsActions {
    func pluginManagementDescriptors() -> [PluginManagementDescriptor] {
        let snapshot = CmuxPluginRuntime.shared.currentSnapshot()
        let valid = snapshot.plugins.map { descriptor in
            PluginManagementDescriptor(
                id: descriptor.plugin.manifest.id,
                displayName: descriptor.plugin.manifest.displayName,
                isEnabled: descriptor.isEnabled,
                needsApproval: !descriptor.isApproved,
                requestedCapabilities: pluginRequestedCapabilities(for: descriptor.plugin.manifest),
                loadError: CmuxPluginRuntime.shared.pluginError(for: descriptor.plugin.manifest.id)
            )
        }
        let failures = snapshot.failures.map { failure in
            let directoryName = failure.directoryURL.lastPathComponent
                .components(separatedBy: .controlCharacters)
                .joined(separator: "�")
            return PluginManagementDescriptor(
                id: failure.directoryURL.lastPathComponent,
                displayName: directoryName,
                isEnabled: false,
                needsApproval: false,
                canManage: false,
                loadError: localizedPluginLoadFailure(failure)
            )
        }
        return (valid + failures).sorted { $0.id < $1.id }
    }

    func approvePlugin(_ pluginID: String) {
        CmuxPluginRuntime.shared.approveAll(pluginID: pluginID)
    }

    func setPluginEnabled(_ enabled: Bool, pluginID: String) {
        CmuxPluginRuntime.shared.setEnabled(enabled, pluginID: pluginID)
    }

    func pluginShortcutDescriptors() -> [PluginShortcutDescriptor] {
        let snapshot = CmuxPluginRuntime.shared.currentSnapshot()
        return snapshot.plugins
            .filter { $0.isEnabled && $0.permissions.pluginScopes.contains(.paletteActions) }
            .flatMap { descriptor -> [PluginShortcutDescriptor] in
                let pluginID = descriptor.plugin.manifest.id
                let pluginName = descriptor.plugin.manifest.displayName
                return descriptor.plugin.manifest.actions.compactMap {
                    action -> PluginShortcutDescriptor? in
                    guard descriptor.permissions.allowsAction(action.id) else { return nil }
                    let actionID = CmuxPluginRegistry.namespacedActionID(
                        pluginID: pluginID,
                        actionID: action.id
                    )
                    let shortcut = CmuxPluginShortcutSettings.shortcut(
                        for: actionID,
                        defaultValue: action.defaultShortcut
                    )
                    return PluginShortcutDescriptor(
                        id: actionID,
                        title: action.title,
                        subtitle: String(
                            format: String(
                                localized: "settings.plugin.shortcutSubtitle",
                                defaultValue: "Plugin • %@"
                            ),
                            pluginName
                        ),
                        shortcut: shortcut?.cmuxSettingsStoredShortcut,
                        conflictDisplayName: shortcut.flatMap {
                            pluginShortcutConflictName($0, excluding: actionID)
                        }
                    )
                }
            }
            .sorted { $0.id < $1.id }
    }

    func setPluginShortcut(_ shortcut: CmuxSettings.StoredShortcut, actionID: String) {
        let appShortcut = StoredShortcut(cmuxSettingsStoredShortcut: shortcut)
        guard CmuxPluginRuntime.shared.activePluginActionIDs().contains(actionID) else { return }
        guard KeyboardShortcutSettings.pluginShortcutConflict(
            appShortcut,
            excluding: actionID
        ) == nil else { return }
        CmuxPluginShortcutSettings.set(appShortcut, for: actionID)
    }

    func pluginShortcutConflict(
        _ shortcut: CmuxSettings.StoredShortcut,
        actionID: String
    ) -> String? {
        guard CmuxPluginRuntime.shared.activePluginActionIDs().contains(actionID) else {
            return String(
                localized: "settings.plugins.shortcut.actionUnavailable",
                defaultValue: "Unavailable plugin action"
            )
        }
        return pluginShortcutConflictName(
            StoredShortcut(cmuxSettingsStoredShortcut: shortcut),
            excluding: actionID
        )
    }

    private func pluginRequestedCapabilities(for manifest: CmuxExtensionManifest) -> [String] {
        var capabilities = [String(
            localized: "settings.plugins.capability.executable",
            defaultValue: "Run plugin executable"
        )]
        capabilities.append(contentsOf: manifest.pluginScopes.map(localizedPluginScope))
        capabilities.append(contentsOf: manifest.eventSubscriptions.map(localizedPluginEvent))
        capabilities.append(contentsOf: manifest.actions.map {
            String(
                format: String(
                    localized: "settings.plugins.capability.action",
                    defaultValue: "Action: %@"
                ),
                $0.title
            )
        })
        return capabilities
    }

    private func localizedPluginScope(_ scope: CmuxExtensionPluginScope) -> String {
        switch scope {
        case .eventHooks:
            return String(localized: "settings.plugins.capability.eventHooks", defaultValue: "Lifecycle events")
        case .paletteActions:
            return String(localized: "settings.plugins.capability.paletteActions", defaultValue: "Command palette actions")
        case .paneContent:
            return String(localized: "settings.plugins.capability.paneContent", defaultValue: "Pane content")
        case .workspaceBadges:
            return String(localized: "settings.plugins.capability.workspaceBadges", defaultValue: "Workspace badges")
        }
    }

    private func localizedPluginEvent(_ event: CmuxExtensionEvent) -> String {
        switch event {
        case .workspaceCreated:
            return String(localized: "settings.plugins.event.workspaceCreated", defaultValue: "Workspace created")
        case .workspaceClosed:
            return String(localized: "settings.plugins.event.workspaceClosed", defaultValue: "Workspace closed")
        case .paneCreated:
            return String(localized: "settings.plugins.event.paneCreated", defaultValue: "Pane created")
        case .paneClosed:
            return String(localized: "settings.plugins.event.paneClosed", defaultValue: "Pane closed")
        case .surfaceCreated:
            return String(localized: "settings.plugins.event.surfaceCreated", defaultValue: "Surface created")
        case .surfaceClosed:
            return String(localized: "settings.plugins.event.surfaceClosed", defaultValue: "Surface closed")
        case .agentSessionStarted:
            return String(localized: "settings.plugins.event.agentStarted", defaultValue: "Agent session started")
        case .agentSessionStateChanged:
            return String(localized: "settings.plugins.event.agentStateChanged", defaultValue: "Agent session state changed")
        case .agentSessionEnded:
            return String(localized: "settings.plugins.event.agentEnded", defaultValue: "Agent session ended")
        case .notificationPosted:
            return String(localized: "settings.plugins.event.notificationPosted", defaultValue: "Notification posted")
        case .gitBranchChanged:
            return String(localized: "settings.plugins.event.gitBranchChanged", defaultValue: "Git branch changed")
        }
    }

    private func pluginShortcutConflictName(
        _ shortcut: StoredShortcut,
        excluding actionID: String
    ) -> String? {
        guard let conflictID = KeyboardShortcutSettings.pluginShortcutConflict(
            shortcut,
            excluding: actionID
        ) else { return nil }
        if let builtIn = ShortcutAction(rawValue: conflictID) {
            return builtIn.displayName
        }
        let snapshot = CmuxPluginRuntime.shared.currentSnapshot()
        for descriptor in snapshot.plugins {
            let pluginID = descriptor.plugin.manifest.id
            for action in descriptor.plugin.manifest.actions
            where CmuxPluginRegistry.namespacedActionID(
                pluginID: pluginID,
                actionID: action.id
            ) == conflictID {
                return action.title
            }
        }
        return conflictID
    }

    private func localizedPluginLoadFailure(_ failure: CmuxPluginLoadFailure) -> String {
        switch failure.code {
        case .unreadableDirectory:
            return String(localized: "settings.plugins.error.unreadableDirectory", defaultValue: "The plugin directory could not be read.")
        case .missingManifest:
            return String(localized: "settings.plugins.error.missingManifest", defaultValue: "manifest.json is missing.")
        case .unreadableManifest:
            return String(localized: "settings.plugins.error.unreadableManifest", defaultValue: "manifest.json could not be read or is too large.")
        case .malformedManifest:
            return String(localized: "settings.plugins.error.malformedManifest", defaultValue: "manifest.json could not be decoded.")
        case .invalidManifest:
            return String(localized: "settings.plugins.error.invalidManifest", defaultValue: "The plugin manifest contains an invalid or unsupported declaration.")
        case .directoryIdentifierMismatch:
            return String(localized: "settings.plugins.error.identifierMismatch", defaultValue: "The manifest identifier does not match its directory name.")
        case .missingEntrypoint:
            return String(localized: "settings.plugins.error.missingExecutable", defaultValue: "The declared plugin executable is missing or cannot be run.")
        case .duplicateIdentifier:
            return String(localized: "settings.plugins.error.duplicateIdentifier", defaultValue: "Another plugin already uses this identifier.")
        }
    }
}
