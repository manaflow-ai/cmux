import CmuxSettings

extension ShortcutListModel {
    /// Persists the optional global prefix independently of unrelated action
    /// bindings. Chord entries are rebased by the prefix-chord mutation path
    /// before this leaf is written, while non-chord actions remain untouched.
    func writePrefix(_ value: StoredShortcut) async {
        guard let normalized = ShortcutPrefixPolicy().normalized(value) else { return }
        prefixWriteGeneration &+= 1
        let generation = prefixWriteGeneration
        let previous = prefix
        prefix = normalized
        let predecessor = prefixWriteTail
        let request = Task.detached { [weak self] in
            await predecessor?.value
            guard let self else { return }
            await self.persistPrefix(
                normalized,
                previous: previous,
                generation: generation
            )
        }
        prefixWriteTail = request
        await request.value
        if prefixWriteGeneration == generation {
            prefixWriteTail = nil
        }
    }

    private func persistPrefix(
        _ normalized: StoredShortcut,
        previous: StoredShortcut,
        generation: UInt64
    ) async {
        do {
            try await jsonStore.set(normalized, for: catalog.shortcuts.prefix)
            let committed = ShortcutPrefixPolicy().normalized(
                await jsonStore.value(for: catalog.shortcuts.prefix)
            ) ?? .unbound
            guard prefixWriteGeneration == generation else { return }
            prefix = committed
            onShortcutsChanged()
        } catch {
            guard prefixWriteGeneration == generation else { return }
            let committed = ShortcutPrefixPolicy().normalized(
                await jsonStore.value(for: catalog.shortcuts.prefix)
            ) ?? previous
            prefix = committed
            errorLog.record(error, keyID: catalog.shortcuts.prefix.id)
        }
    }

    /// Removes the prefix key after all earlier prefix writes have drained.
    /// Reset Defaults must not let a queued older write resurrect the leader.
    func resetPrefix() async {
        prefixWriteGeneration &+= 1
        let generation = prefixWriteGeneration
        let predecessor = prefixWriteTail
        let previous = prefix
        prefix = .unbound
        let request = Task.detached { [weak self] in
            await predecessor?.value
            await self?.persistResetPrefix(previous: previous, generation: generation)
        }
        prefixWriteTail = request
        await request.value
        if prefixWriteGeneration == generation {
            prefixWriteTail = nil
        }
    }

    private func persistResetPrefix(
        previous: StoredShortcut,
        generation: UInt64
    ) async {
        do {
            try await jsonStore.reset(catalog.shortcuts.prefix)
            guard prefixWriteGeneration == generation else { return }
            prefix = .unbound
            onShortcutsChanged()
        } catch {
            guard prefixWriteGeneration == generation else { return }
            prefix = ShortcutPrefixPolicy().normalized(
                await jsonStore.value(for: catalog.shortcuts.prefix)
            ) ?? previous
            errorLog.record(error, keyID: catalog.shortcuts.prefix.id)
        }
    }

    /// Rewrites the first stroke of every persisted chord through the same
    /// binding map used by ordinary Settings edits. This keeps an existing
    /// chord reachable when the shared prefix changes.
    func rebaseChordBindings(to firstStroke: ShortcutStroke) async {
        let current = latestBindings
        var rebased = current
        for (actionID, shortcut) in current where shortcut.hasChord {
            guard let second = shortcut.second else { continue }
            rebased[actionID] = StoredShortcut(first: firstStroke, second: second)
        }
        guard rebased != current else { return }

        pendingWriteGeneration &+= 1
        let generation = pendingWriteGeneration
        pendingBindings = rebased
        bindings = rebased
        do {
            // Each leaf write preserves malformed or unknown sibling entries
            // that the snapshot decoder intentionally retains as managed.
            for actionID in rebased.keys.sorted()
                where rebased[actionID] != current[actionID] {
                let key = JSONKey<StoredShortcut>(
                    id: "\(catalog.shortcuts.bindings.id).\(actionID)",
                    defaultValue: .unbound
                )
                try await jsonStore.set(rebased[actionID] ?? .unbound, for: key)
            }
            guard pendingWriteGeneration == generation else { return }
            pendingBindings = nil
            onShortcutsChanged()
        } catch {
            guard pendingWriteGeneration == generation else { return }
            let committed = await jsonStore.value(for: catalog.shortcuts.bindingSnapshot)
            bindings = committed.bindings
            managedBindingActionIDs = committed.managedActionIDs
            pendingBindings = nil
            errorLog.record(error, keyID: catalog.shortcuts.bindings.id)
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
