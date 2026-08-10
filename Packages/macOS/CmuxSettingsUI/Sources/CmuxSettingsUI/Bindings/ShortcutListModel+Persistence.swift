import CmuxSettings

extension ShortcutListModel {
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
