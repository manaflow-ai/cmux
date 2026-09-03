import CmuxExtensionKit
import CmuxSettings
import CmuxSettingsUI
import Foundation

extension HostSettingsActions {
    func pluginManagementDescriptors() -> [PluginManagementDescriptor] {
        let snapshot = pluginRuntime.currentSnapshot()
        let permissionStoreError = snapshot.permissionStoreLoadFailure.map {
            localizedPluginPermissionStoreFailure($0)
        }
        let valid = snapshot.plugins.map { descriptor in
            PluginManagementDescriptor(
                id: descriptor.plugin.manifest.id,
                displayName: sanitizedPluginDisplayText(descriptor.plugin.manifest.displayName),
                isEnabled: descriptor.isEnabled,
                needsApproval: !descriptor.isApproved,
                requestedCapabilities: pluginRequestedCapabilities(for: descriptor.plugin.manifest),
                loadError: pluginRuntime.pluginError(
                    for: descriptor.plugin.manifest.id
                ) ?? permissionStoreError
            )
        }
        let failures = snapshot.failures.map { failure in
            let directoryName = sanitizedPluginDisplayText(
                failure.directoryURL.lastPathComponent
            )
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

    func approveAndEnablePlugin(_ pluginID: String) {
        pluginRuntime.approveAll(pluginID: pluginID)
    }

    func setPluginEnabled(_ enabled: Bool, pluginID: String) {
        pluginRuntime.setEnabled(enabled, pluginID: pluginID)
    }

    func pluginShortcutDescriptors() -> [PluginShortcutDescriptor] {
        let snapshot = pluginRuntime.currentSnapshot()
        let activeBindings = pluginRuntime.activePluginShortcutBindings()
        pluginRuntime.setConfiguredCmuxShortcutBindings(
            AppDelegate.shared?.configuredCmuxShortcutBindingsForPluginConflicts() ?? [:]
        )
        let conflicts = KeyboardShortcutSettings.pluginShortcutConflicts(
            in: activeBindings,
            configuredCmuxShortcuts: AppDelegate.shared?
                .configuredCmuxShortcutBindingsForPluginConflicts() ?? [:]
        )
        return snapshot.plugins
            .filter { $0.isEnabled && $0.permissions.pluginScopes.contains(.paletteActions) }
            .flatMap { descriptor -> [PluginShortcutDescriptor] in
                let pluginID = descriptor.plugin.manifest.id
                let pluginName = sanitizedPluginDisplayText(descriptor.plugin.manifest.displayName)
                return descriptor.plugin.manifest.actions.compactMap {
                    action -> PluginShortcutDescriptor? in
                    guard descriptor.permissions.allowsAction(action.id) else { return nil }
                    let actionID = CmuxPluginRegistry.namespacedActionID(
                        pluginID: pluginID,
                        actionID: action.id
                    )
                    let shortcut = pluginRuntime.effectivePluginShortcut(
                        for: actionID,
                        defaultValue: action.defaultShortcut
                    )
                    return PluginShortcutDescriptor(
                        id: actionID,
                        title: sanitizedPluginDisplayText(action.title),
                        subtitle: String.localizedStringWithFormat(
                            String(
                                localized: "settings.plugin.shortcutSubtitle",
                                defaultValue: "Plugin • %@"
                            ),
                            pluginName
                        ),
                        shortcut: shortcut?.cmuxSettingsStoredShortcut,
                        conflictDisplayName: conflicts[actionID].map {
                            pluginShortcutConflictName(for: $0)
                        }
                    )
                }
            }
            .sorted { $0.id < $1.id }
    }

    func setPluginShortcut(_ shortcut: CmuxSettings.StoredShortcut, actionID: String) {
        let appShortcut = StoredShortcut(cmuxSettingsStoredShortcut: shortcut)
        guard pluginRuntime.activePluginActionIDs().contains(actionID) else { return }
        let activeBindings = pluginRuntime.activePluginShortcutBindings()
        guard KeyboardShortcutSettings.pluginShortcutConflict(
            appShortcut,
            excluding: actionID,
            activePluginBindings: activeBindings,
            configuredCmuxShortcuts: AppDelegate.shared?
                .configuredCmuxShortcutBindingsForPluginConflicts() ?? [:]
        ) == nil else { return }
        pluginRuntime.setPluginShortcut(appShortcut, actionID: actionID)
    }

    func pluginShortcutConflict(
        _ shortcut: CmuxSettings.StoredShortcut,
        actionID: String
    ) -> String? {
        guard pluginRuntime.activePluginActionIDs().contains(actionID) else {
            return String(
                localized: "settings.plugins.shortcut.actionUnavailable",
                defaultValue: "Unavailable plugin action"
            )
        }
        let conflictID = KeyboardShortcutSettings.pluginShortcutConflict(
            StoredShortcut(cmuxSettingsStoredShortcut: shortcut),
            excluding: actionID,
            activePluginBindings: pluginRuntime.activePluginShortcutBindings(),
            configuredCmuxShortcuts: AppDelegate.shared?
                .configuredCmuxShortcutBindingsForPluginConflicts() ?? [:]
        )
        return conflictID.map { pluginShortcutConflictName(for: $0) }
    }

    private func pluginRequestedCapabilities(for manifest: CmuxExtensionManifest) -> [String] {
        var capabilities = [String(
            localized: "settings.plugins.capability.executable",
            defaultValue: "Run plugin executable"
        )]
        capabilities.append(contentsOf: manifest.pluginScopes.map(localizedPluginScope))
        capabilities.append(contentsOf: manifest.eventSubscriptions.map(localizedPluginEvent))
        capabilities.append(contentsOf: manifest.actions.map {
            String.localizedStringWithFormat(
                String(
                    localized: "settings.plugins.capability.action",
                    defaultValue: "Action: %@"
                ),
                sanitizedPluginDisplayText($0.title)
            )
        })
        return capabilities
    }

    /// Removes invisible/control scalars before plugin text reaches Settings.
    /// Validation rejects these declarations at load time; keeping this
    /// projection defensive also protects settings rows from future manifest
    /// schema extensions or an already-cached snapshot.
    private func sanitizedPluginDisplayText(_ value: String) -> String {
        let visibleScalars = value.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && scalar.value != 0x200B
                && scalar.value != 0x200C
                && scalar.value != 0x200D
                && scalar.value != 0x200E
                && scalar.value != 0x200F
                && !(0x202A...0x202E).contains(scalar.value)
                && !(0x2066...0x2069).contains(scalar.value)
                && scalar.value != 0xFEFF
        }
        return String(String.UnicodeScalarView(visibleScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func pluginShortcutConflictName(for conflictID: String) -> String {
        if let builtIn = ShortcutAction(rawValue: conflictID) {
            return builtIn.displayName
        }
        let snapshot = pluginRuntime.currentSnapshot()
        for descriptor in snapshot.plugins {
            let pluginID = descriptor.plugin.manifest.id
            for action in descriptor.plugin.manifest.actions
            where CmuxPluginRegistry.namespacedActionID(
                pluginID: pluginID,
                actionID: action.id
            ) == conflictID {
                return sanitizedPluginDisplayText(action.title)
            }
        }
        return conflictID
    }

    private func localizedPluginPermissionStoreFailure(
        _: CmuxPluginPermissionStoreLoadFailure
    ) -> String {
        String(
            localized: "settings.plugins.error.permissionsUnreadable",
            defaultValue: "Plugin permissions could not be loaded. The existing grants were left unchanged."
        )
    }

    private func localizedPluginLoadFailure(_ failure: CmuxPluginLoadFailure) -> String {
        switch failure.code {
        case .unreadableDirectory:
            return String(localized: "settings.plugins.error.unreadableDirectory", defaultValue: "The plugin directory could not be read.")
        case .missingManifest:
            return String(localized: "settings.plugins.error.missingManifest", defaultValue: "The plugin could not be loaded because its descriptor is missing.")
        case .unreadableManifest:
            return String(localized: "settings.plugins.error.unreadableManifest", defaultValue: "The plugin could not be loaded from disk.")
        case .malformedManifest:
            return String(localized: "settings.plugins.error.malformedManifest", defaultValue: "The plugin descriptor could not be read.")
        case .invalidManifest:
            return String(localized: "settings.plugins.error.invalidManifest", defaultValue: "The plugin declaration is invalid or unsupported.")
        case .directoryIdentifierMismatch:
            return String(localized: "settings.plugins.error.identifierMismatch", defaultValue: "The plugin identity does not match its installation.")
        case .missingEntrypoint:
            return String(localized: "settings.plugins.error.missingExecutable", defaultValue: "The declared plugin executable is missing or cannot be run.")
        case .duplicateIdentifier:
            return String(localized: "settings.plugins.error.duplicateIdentifier", defaultValue: "Another plugin already uses this identifier.")
        }
    }
}
