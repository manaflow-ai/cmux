import CmuxSettings

extension ShortcutListModel {
    /// Persists the optional global prefix independently of the action map.
    /// Keeping this mutation separate means changing the leader never rewrites
    /// unrelated shortcut bindings or their managed-action bookkeeping.
    func writePrefix(_ value: StoredShortcut) async {
        guard let normalized = ShortcutPrefixPolicy().normalized(value) else { return }
        let previous = prefix
        pendingPrefix = normalized
        prefix = normalized
        do {
            try await jsonStore.set(normalized, for: catalog.shortcuts.prefix)
            // Retire the local-write marker even when the file watcher has not
            // delivered its matching echo yet. A direct actor read also makes
            // the model converge if a watcher coalesces the write with a
            // subsequent external edit.
            let committed = ShortcutPrefixPolicy().normalized(
                await jsonStore.value(for: catalog.shortcuts.prefix)
            ) ?? .unbound
            if pendingPrefix == normalized {
                pendingPrefix = nil
                prefix = committed
            }
            onShortcutsChanged()
        } catch {
            if pendingPrefix == normalized {
                pendingPrefix = nil
                prefix = previous
            }
            errorLog.record(error, keyID: catalog.shortcuts.prefix.id)
        }
    }

    /// Persists one binding leaf, or resets the complete map for Reset Defaults.
    func write(
        _ updated: [String: StoredShortcut],
        clearingLegacyFor action: ShortcutAction? = nil,
        resetAllLegacy: Bool = false
    ) async {
        pendingWriteGeneration += 1
        let generation = pendingWriteGeneration
        pendingBindings = updated
        bindings = updated
        if let action {
            managedBindingActionIDs.insert(action.rawValue)
        } else {
            managedBindingActionIDs.removeAll()
        }

        do {
            if let action {
                let key = JSONKey<StoredShortcut>(
                    id: "\(catalog.shortcuts.bindings.id).\(action.rawValue)",
                    defaultValue: .unbound
                )
                try await jsonStore.set(
                    updated[action.rawValue] ?? .unbound,
                    for: key
                )
            } else {
                try await jsonStore.reset(catalog.shortcuts.bindings)
            }
            if resetAllLegacy {
                await userDefaultsStore?.resetAllLegacyShortcutBindings()
                legacyBindings.removeAll()
            } else if let action, legacyBindings[action.rawValue] != nil {
                await userDefaultsStore?.resetLegacyShortcutBinding(for: action)
                legacyBindings.removeValue(forKey: action.rawValue)
            }
            onShortcutsChanged()
            if pendingWriteGeneration == generation {
                pendingBindings = nil
            }
        } catch {
            if pendingWriteGeneration == generation {
                let committed = await jsonStore.value(
                    for: catalog.shortcuts.bindingSnapshot
                )
                if pendingWriteGeneration == generation {
                    let changedActionIds = Set(bindings.keys)
                        .union(committed.bindings.keys)
                        .filter { bindings[$0] != committed.bindings[$0] }
                    bindings = committed.bindings
                    managedBindingActionIDs = committed.managedActionIDs
                    pendingBindings = nil
                    pruneRestoreShortcuts()
                    pruneConflictRejections()
                    pruneNumberedDigitRejections(
                        changedActionIds: Set(changedActionIds)
                    )
                }
            }
            errorLog.record(error, keyID: catalog.shortcuts.bindings.id)
        }
    }
}
