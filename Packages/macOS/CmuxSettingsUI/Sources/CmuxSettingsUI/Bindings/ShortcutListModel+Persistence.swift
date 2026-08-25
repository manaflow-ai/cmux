import CmuxSettings

extension ShortcutListModel {
    /// Enqueues one settings mutation behind every earlier shortcut mutation.
    /// The operation closure is MainActor-isolated so the model's optimistic
    /// state and its persistence side effects share one ordering boundary.
    @discardableResult
    private func enqueueShortcutPersistence(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let predecessor = shortcutWriteTail
        let request = Task { @MainActor in
            await predecessor?.value
            await operation()
        }
        shortcutWriteTail = request
        return request
    }

    /// Persists the optional global prefix independently of unrelated action
    /// bindings. Chord entries are rebased by the prefix-chord mutation path
    /// before this leaf is written, while non-chord actions remain untouched.
    func writePrefix(
        _ value: StoredShortcut,
        rebasingChordsTo firstStroke: ShortcutStroke? = nil
    ) async {
        guard let normalized = ShortcutPrefixPolicy().normalized(value) else { return }
        prefixWriteGeneration &+= 1
        let generation = prefixWriteGeneration
        let previous = prefix
        prefix = normalized
        let rebasingGeneration: Int?
        if firstStroke != nil {
            pendingWriteGeneration += 1
            rebasingGeneration = pendingWriteGeneration
        } else {
            rebasingGeneration = nil
        }
        let request = enqueueShortcutPersistence { [weak self] in
            guard let self else { return }
            await self.persistPrefix(
                normalized,
                previous: previous,
                generation: generation,
                rebasingChordsTo: firstStroke,
                rebasingGeneration: rebasingGeneration
            )
        }
        await request.value
    }

    private func persistPrefix(
        _ normalized: StoredShortcut,
        previous: StoredShortcut,
        generation: UInt64,
        rebasingChordsTo firstStroke: ShortcutStroke?,
        rebasingGeneration: Int?
    ) async {
        do {
            if let firstStroke, let rebasingGeneration {
                try await persistRebasedChordBindings(
                    to: firstStroke,
                    generation: rebasingGeneration
                )
            }
            guard prefixWriteGeneration == generation else { return }
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
        let previous = prefix
        prefix = .unbound
        let request = enqueueShortcutPersistence { [weak self] in
            await self?.persistResetPrefix(previous: previous, generation: generation)
        }
        await request.value
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

    /// Rewrites the first stroke of every persisted chord as part of the same
    /// serialized operation that persists the shared prefix. This keeps an
    /// existing chord reachable even when prefix edits overlap.
    private func persistRebasedChordBindings(
        to firstStroke: ShortcutStroke,
        generation: Int
    ) async throws {
        // Read the snapshot at execution time, after all earlier queued
        // mutations have landed. The model cache may still be cold or waiting
        // for a coalesced file-watch event, so it is not a safe rebase source.
        let persisted = await jsonStore.value(for: catalog.shortcuts.bindingSnapshot)
        let current = persisted.bindings
        var rebased = current
        for (actionID, shortcut) in current where shortcut.hasChord {
            guard let second = shortcut.second else { continue }
            rebased[actionID] = StoredShortcut(first: firstStroke, second: second)
        }
        guard rebased != current else {
            // A prefix request still advances the binding generation so it
            // orders behind any already-issued binding write. If that write
            // has landed by the time we observe that there are no chords to
            // rebase, reconcile it here instead of leaving its optimistic
            // snapshot pending forever.
            guard pendingWriteGeneration == generation else { return }
            let changedActionIds = Set(bindings.keys)
                .union(persisted.bindings.keys)
                .filter { bindings[$0] != persisted.bindings[$0] }
            bindings = persisted.bindings
            managedBindingActionIDs = persisted.managedActionIDs
            pendingBindings = nil
            pruneRestoreShortcuts()
            pruneConflictRejections()
            pruneNumberedDigitRejections(
                changedActionIds: Set(changedActionIds)
            )
            return
        }

        // A newer binding request may already have been issued while this
        // prefix operation waited in the queue. Keep that request's
        // optimistic projection; the FIFO operation will reconcile it after
        // this rebase lands.
        if pendingWriteGeneration == generation {
            pendingBindings = rebased
            bindings = rebased
            managedBindingActionIDs = persisted.managedActionIDs
        }
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
            let committed = await jsonStore.value(for: catalog.shortcuts.bindingSnapshot)
            bindings = committed.bindings
            managedBindingActionIDs = committed.managedActionIDs
            pendingBindings = nil
            pruneRestoreShortcuts()
            pruneConflictRejections()
            pruneNumberedDigitRejections(
                changedActionIds: Set(current.keys).union(committed.bindings.keys)
                    .filter { current[$0] != committed.bindings[$0] }
            )
        } catch {
            guard pendingWriteGeneration == generation else { throw error }
            let committed = await jsonStore.value(for: catalog.shortcuts.bindingSnapshot)
            bindings = committed.bindings
            managedBindingActionIDs = committed.managedActionIDs
            pendingBindings = nil
            throw error
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

        let request = enqueueShortcutPersistence { [weak self] in
            await self?.persistBindings(
                updated,
                generation: generation,
                clearingLegacyFor: action,
                resetAllLegacy: resetAllLegacy
            )
        }
        await request.value
    }

    private func persistBindings(
        _ updated: [String: StoredShortcut],
        generation: Int,
        clearingLegacyFor action: ShortcutAction?,
        resetAllLegacy: Bool
    ) async {
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
                let committed = await jsonStore.value(
                    for: catalog.shortcuts.bindingSnapshot
                )
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
