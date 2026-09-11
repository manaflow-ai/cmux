import AppKit
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
                } else if let defaultShortcut = Self.parsePluginShortcut(action.defaultShortcut),
                          !defaultShortcut.isUnbound {
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

    /// Returns only plugin bindings whose indexed stroke can match `event`.
    /// The key-event path never copies or scans the complete binding table.
    func routablePluginShortcutActionIDs(
        for event: NSEvent,
        completingChord: Bool
    ) -> [String] {
        guard let eventStroke = ShortcutStroke.from(event: event, requireModifier: false) else {
            return []
        }
        let lookupStrokes = shortcutLookupStrokes(for: eventStroke)
        lock.lock()
        let index = completingChord
            ? routablePluginShortcutSecondIndex
            : routablePluginShortcutFirstIndex
        var actionIDs = Set<String>()
        for stroke in lookupStrokes {
            actionIDs.formUnion(index[stroke] ?? [])
        }
        lock.unlock()
        return actionIDs.sorted()
    }

    /// Returns one indexed binding for final event matching.
    func routablePluginShortcut(for actionID: String) -> StoredShortcut? {
        lock.lock()
        defer { lock.unlock() }
        return routablePluginShortcuts[actionID]
    }

    /// Returns only chord bindings whose first stroke matches `event`.
    func routablePluginChordShortcuts(for event: NSEvent) -> [StoredShortcut] {
        routablePluginShortcutActionIDs(for: event, completingChord: false)
            .compactMap { actionID in
                guard let shortcut = routablePluginShortcut(for: actionID), shortcut.hasChord else {
                    return nil
                }
                return shortcut
            }
    }

    /// Updates the configured cmux action projection that has routing priority
    /// over plugin shortcuts.
    func setConfiguredCmuxShortcutBindings(_ bindings: [String: StoredShortcut]) {
        lock.lock()
        guard configuredCmuxShortcutBindings != bindings else {
            lock.unlock()
            return
        }
        configuredCmuxShortcutBindings = bindings
        lock.unlock()
        refreshRoutablePluginShortcuts()
    }

    /// Returns namespaced action ids currently exposed by enabled plugins.
    func activePluginActionIDs() -> Set<String> {
        let currentSnapshot = currentSnapshot()
        return Set(currentSnapshot.plugins.flatMap { descriptor -> [String] in
            guard descriptor.isEnabled,
                  descriptor.permissions.pluginScopes.contains(.paletteActions) else {
                return []
            }
            let pluginID = descriptor.plugin.manifest.id
            return descriptor.plugin.manifest.actions
                .filter { descriptor.permissions.allowsAction($0.id) }
                .map { CmuxPluginRegistry.namespacedActionID(pluginID: pluginID, actionID: $0.id) }
        })
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
                name: .cmuxPluginShortcutsDidChange,
                object: nil
            )
        }
    }

    func refreshRoutablePluginShortcuts() {
        let candidates = activePluginShortcutBindings()
        let invocableActionIDs = invocablePluginActionIDs()
        lock.lock()
        let configuredBindings = configuredCmuxShortcutBindings
        lock.unlock()
        let conflicts = KeyboardShortcutSettings.pluginShortcutConflicts(
            in: candidates,
            configuredCmuxShortcuts: configuredBindings
        )
        var next: [String: StoredShortcut] = [:]
        for (actionID, shortcut) in candidates {
            guard invocableActionIDs.contains(actionID), conflicts[actionID] == nil else { continue }
            next[actionID] = shortcut
        }
        lock.lock()
        routablePluginShortcuts = next
        routablePluginShortcutFirstIndex = shortcutIndex(for: next) { $0.firstStroke }
        routablePluginShortcutSecondIndex = shortcutIndex(for: next) { $0.secondStroke }
        lock.unlock()
    }

    private func shortcutIndex(
        for bindings: [String: StoredShortcut],
        _ stroke: (StoredShortcut) -> ShortcutStroke?
    ) -> [ShortcutStroke: [String]] {
        var index: [ShortcutStroke: [String]] = [:]
        for (actionID, shortcut) in bindings {
            guard let stroke = stroke(shortcut), !stroke.key.isEmpty else { continue }
            for lookupStroke in shortcutLookupStrokes(for: stroke) {
                index[lookupStroke, default: []].append(actionID)
            }
            if let resolvedKeyCode = stroke.resolvedKeyCode() {
                let resolvedStroke = ShortcutStroke(
                    key: stroke.key,
                    command: stroke.command,
                    shift: stroke.shift,
                    option: stroke.option,
                    control: stroke.control,
                    keyCode: resolvedKeyCode
                )
                index[resolvedStroke, default: []].append(actionID)
            }
        }
        return index.mapValues { Array(Set($0)).sorted() }
    }

    private func shortcutLookupStrokes(for stroke: ShortcutStroke) -> [ShortcutStroke] {
        guard stroke.keyCode != nil else { return [stroke] }
        return [
            stroke,
            ShortcutStroke(
                key: stroke.key,
                command: stroke.command,
                shift: stroke.shift,
                option: stroke.option,
                control: stroke.control
            ),
        ]
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
