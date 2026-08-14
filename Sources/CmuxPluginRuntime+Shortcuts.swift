import CmuxExtensionKit
import CmuxSettingsUI
import Foundation

extension CmuxPluginRuntime {
    /// Returns a synchronously readable plugin shortcut for AppKit routing.
    func pluginShortcut(for actionID: String) -> StoredShortcut? {
        lock.lock()
        let store = pluginShortcutStore
        lock.unlock()
        return store?.shortcut(for: actionID)
    }

    /// Returns a persisted override or a valid manifest default.
    func effectivePluginShortcut(
        for actionID: String,
        defaultValue: String?
    ) -> StoredShortcut? {
        if let stored = pluginShortcut(for: actionID) {
            return stored
        }
        guard let parsed = Self.parsePluginShortcut(defaultValue),
              !parsed.isUnbound else {
            return nil
        }
        return parsed
    }

    /// Returns all persisted plugin shortcuts for conflict checks.
    func pluginShortcuts() -> [String: StoredShortcut] {
        lock.lock()
        let store = pluginShortcutStore
        lock.unlock()
        return store?.shortcuts() ?? [:]
    }

    /// Returns effective bindings for every enabled, approved plugin action.
    func activePluginShortcutBindings() -> [String: StoredShortcut] {
        let currentSnapshot = currentSnapshot()
        lock.lock()
        let store = pluginShortcutStore
        lock.unlock()
        var bindings: [String: StoredShortcut] = [:]
        for descriptor in currentSnapshot.plugins where descriptor.isEnabled {
            guard descriptor.permissions.pluginScopes.contains(.paletteActions) else { continue }
            let pluginID = descriptor.plugin.manifest.id
            for action in descriptor.plugin.manifest.actions where descriptor.permissions.allowsAction(action.id) {
                let actionID = CmuxPluginRegistry.namespacedActionID(pluginID: pluginID, actionID: action.id)
                if let stored = store?.shortcut(for: actionID) {
                    bindings[actionID] = stored
                } else if let defaultShortcut = Self.parsePluginShortcut(action.defaultShortcut) {
                    bindings[actionID] = defaultShortcut
                }
            }
        }
        return bindings
    }

    /// Returns conflict-free effective plugin bindings for key-event routing.
    func routablePluginShortcutBindings() -> [String: StoredShortcut] {
        lock.lock()
        defer { lock.unlock() }
        return routablePluginShortcuts
    }

    /// Returns namespaced action ids currently exposed by enabled plugins.
    func activePluginActionIDs() -> Set<String> {
        let currentSnapshot = currentSnapshot()
        return Set(currentSnapshot.plugins.compactMap { descriptor in
            guard descriptor.isEnabled,
                  descriptor.permissions.pluginScopes.contains(.paletteActions) else {
                return nil
            }
            let pluginID = descriptor.plugin.manifest.id
            return descriptor.plugin.manifest.actions
                .filter { descriptor.permissions.allowsAction($0.id) }
                .map { CmuxPluginRegistry.namespacedActionID(pluginID: pluginID, actionID: $0.id) }
        }.joined())
    }

    /// Persists one active plugin shortcut through the shared JSON settings path.
    func setPluginShortcut(_ shortcut: StoredShortcut, actionID: String) {
        guard Self.isSafePluginActionID(actionID), activePluginActionIDs().contains(actionID) else { return }
        lock.lock()
        let store = pluginShortcutStore
        lock.unlock()
        store?.set(shortcut, actionID: actionID)
    }

    /// Removes an active plugin shortcut override.
    func clearPluginShortcut(actionID: String) {
        guard Self.isSafePluginActionID(actionID), activePluginActionIDs().contains(actionID) else { return }
        lock.lock()
        let store = pluginShortcutStore
        lock.unlock()
        store?.clear(actionID: actionID)
    }

    func reloadPluginShortcutsFromDisk() {
        lock.lock()
        let store = pluginShortcutStore
        lock.unlock()
        // The AsyncStream watcher owns the authoritative value; this direct
        // read keeps the synchronous key path current after an external edit.
        guard let store else { return }
        store.refreshFromDisk()
        refreshRoutablePluginShortcuts()
        Task { @MainActor in
            NotificationCenter.default.post(
                name: PluginShortcutSettings.didChangeNotification,
                object: nil
            )
        }
    }

    func refreshRoutablePluginShortcuts() {
        let candidates = activePluginShortcutBindings()
        let invocableActionIDs = invocablePluginActionIDs()
        let conflicts = KeyboardShortcutSettings.pluginShortcutConflicts(in: candidates)
        var next: [String: StoredShortcut] = [:]
        for (actionID, shortcut) in candidates {
            guard invocableActionIDs.contains(actionID), conflicts[actionID] == nil else { continue }
            next[actionID] = shortcut
        }
        lock.lock()
        routablePluginShortcuts = next
        lock.unlock()
    }

    private func invocablePluginActionIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(snapshot.plugins.flatMap { descriptor -> [String] in
            let pluginID = descriptor.plugin.manifest.id
            guard descriptor.isEnabled,
                  actionSubscriptionIDsByPluginID[pluginID]?.isEmpty == false else {
                return []
            }
            return descriptor.plugin.manifest.actions.compactMap { action in
                guard descriptor.permissions.allowsAction(action.id) else { return nil }
                return CmuxPluginRegistry.namespacedActionID(
                    pluginID: pluginID,
                    actionID: action.id
                )
            }
        })
    }

    static func isSafePluginActionID(_ actionID: String) -> Bool {
        guard actionID.hasPrefix("plugin."), actionID.count <= 256 else { return false }
        return actionID.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122)
                || (value >= 48 && value <= 57)
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    static func parsePluginShortcut(_ raw: String?) -> StoredShortcut? {
        guard let raw else { return nil }
        return StoredShortcut.parseConfig(
            strokes: raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init),
            allowBareFirstStroke: false
        )
    }
}
