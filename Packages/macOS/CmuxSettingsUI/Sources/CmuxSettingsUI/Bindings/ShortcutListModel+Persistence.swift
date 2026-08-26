import CmuxSettings

extension ShortcutListModel {
    private enum PrefixRebaseError: Error {
        case chordConflict
    }

    private struct RebasedChordSnapshot {
        struct Entry {
            let actionID: String
            let original: StoredShortcut
            let wasPersisted: Bool
        }

        let entries: [Entry]
        let migratedLegacyActionIDs: Set<String>
    }

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
        var rebasedSnapshot: RebasedChordSnapshot?
        do {
            if let firstStroke, let rebasingGeneration {
                rebasedSnapshot = try await persistRebasedChordBindings(
                    to: firstStroke,
                    generation: rebasingGeneration,
                    prefixGeneration: generation
                )
            }
            guard prefixWriteGeneration == generation else {
                if let rebasedSnapshot {
                    await restoreRebasedChordBindings(rebasedSnapshot)
                }
                return
            }
            try await jsonStore.set(normalized, for: catalog.shortcuts.prefix)
            let committed = ShortcutPrefixPolicy().normalized(
                await jsonStore.value(for: catalog.shortcuts.prefix)
            ) ?? .unbound
            guard prefixWriteGeneration == generation else {
                if let rebasedSnapshot {
                    await restoreRebasedChordBindings(rebasedSnapshot)
                }
                return
            }
            if let rebasedSnapshot {
                await finalizeLegacyRebasedChords(rebasedSnapshot)
            }
            prefix = committed
            onShortcutsChanged()
        } catch {
            if case PrefixRebaseError.chordConflict = error {
                guard prefixWriteGeneration == generation else { return }
                prefix = previous
                prefixRejection = .chordConflict
                return
            }
            guard prefixWriteGeneration == generation else {
                if let rebasedSnapshot {
                    await restoreRebasedChordBindings(rebasedSnapshot)
                }
                return
            }
            if let rebasedSnapshot {
                await restoreRebasedChordBindings(rebasedSnapshot)
            }
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
        generation: Int,
        prefixGeneration: UInt64
    ) async throws -> RebasedChordSnapshot? {
        // Read the snapshot at execution time, after all earlier queued
        // mutations have landed. The model cache may still be cold or waiting
        // for a coalesced file-watch event, so it is not a safe rebase source.
        let persisted = await jsonStore.value(for: catalog.shortcuts.bindingSnapshot)
        var current = persisted.bindings
        var legacyChordActionIDs = Set<String>()
        for (actionID, shortcut) in legacyBindings where
            !persisted.managedActionIDs.contains(actionID) && shortcut.hasChord {
            current[actionID] = shortcut
            legacyChordActionIDs.insert(actionID)
        }
        var rebased = current
        for (actionID, shortcut) in current where shortcut.hasChord {
            guard let second = shortcut.second else { continue }
            rebased[actionID] = StoredShortcut(first: firstStroke, second: second)
        }
        let migratedLegacyActionIDs = legacyChordActionIDs.filter {
            rebased[$0] != current[$0]
        }
        guard prefixWriteGeneration == prefixGeneration else { return nil }
        guard rebased != current else {
            // A prefix request still advances the binding generation so it
            // orders behind any already-issued binding write. If that write
            // has landed by the time we observe that there are no chords to
            // rebase, reconcile it here instead of leaving its optimistic
            // snapshot pending forever.
            guard pendingWriteGeneration == generation else { return nil }
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
            return nil
        }
        let originalEntries: [RebasedChordSnapshot.Entry] = rebased.compactMap { element in
            let (actionID, shortcut) = element
            guard shortcut != current[actionID], let original = current[actionID] else {
                return nil
            }
            return RebasedChordSnapshot.Entry(
                actionID: actionID,
                original: original,
                wasPersisted: persisted.bindings[actionID] != nil
            )
        }
        let rebasedSnapshot = RebasedChordSnapshot(
            entries: originalEntries,
            migratedLegacyActionIDs: migratedLegacyActionIDs
        )
        var appliedActionIDs: [String] = []

        for (actionID, shortcut) in rebased where shortcut.hasChord {
            guard let action = ShortcutAction(rawValue: actionID) else { continue }
            if detectConflict(
                for: action,
                stroke: shortcut,
                overriding: rebased
            ) != nil {
                throw PrefixRebaseError.chordConflict
            }
        }

        // A newer binding request may already have been issued while this
        // prefix operation waited in the queue. Keep that request's
        // optimistic projection; the FIFO operation will reconcile it after
        // this rebase lands.
        if pendingWriteGeneration == generation {
            pendingBindings = rebased
            bindings = rebased
            managedBindingActionIDs = persisted.managedActionIDs
                .union(migratedLegacyActionIDs)
        }
        do {
            // Each leaf write preserves malformed or unknown sibling entries
            // that the snapshot decoder intentionally retains as managed.
            for actionID in rebased.keys.sorted()
                where rebased[actionID] != current[actionID] {
                guard prefixWriteGeneration == prefixGeneration else {
                    await restoreRebasedChordBindings(
                        rebasedSnapshot,
                        actionIDs: appliedActionIDs
                    )
                    return nil
                }
                let key = JSONKey<StoredShortcut>(
                    id: "\(catalog.shortcuts.bindings.id).\(actionID)",
                    defaultValue: .unbound
                )
                try await jsonStore.set(rebased[actionID] ?? .unbound, for: key)
                appliedActionIDs.append(actionID)
            }
            guard prefixWriteGeneration == prefixGeneration else {
                await restoreRebasedChordBindings(
                    rebasedSnapshot,
                    actionIDs: appliedActionIDs
                )
                return nil
            }
            guard pendingWriteGeneration == generation else { return rebasedSnapshot }
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
            return rebasedSnapshot
        } catch {
            if !appliedActionIDs.isEmpty {
                await restoreRebasedChordBindings(
                    rebasedSnapshot,
                    actionIDs: appliedActionIDs
                )
            }
            guard pendingWriteGeneration == generation else { throw error }
            let committed = await jsonStore.value(for: catalog.shortcuts.bindingSnapshot)
            bindings = committed.bindings
            managedBindingActionIDs = committed.managedActionIDs
            pendingBindings = nil
            throw error
        }
    }

    /// Restores the leaves changed by a failed prefix rebase. JSONConfigStore
    /// writes each leaf atomically, so compensating in reverse order returns
    /// the table to its pre-rebase snapshot whenever the underlying failure is
    /// transient; a rollback failure is intentionally retained as the original
    /// settings error so the user still gets one actionable alert.
    private func restoreRebasedChordBindings(
        _ snapshot: RebasedChordSnapshot,
        actionIDs: [String]? = nil
    ) async {
        let entriesByID = Dictionary(
            uniqueKeysWithValues: snapshot.entries.map { ($0.actionID, $0) }
        )
        let ids = actionIDs ?? snapshot.entries.map(\.actionID).sorted()
        for actionID in ids.reversed() {
            guard let entry = entriesByID[actionID] else { continue }
            let key = JSONKey<StoredShortcut>(
                id: "\(catalog.shortcuts.bindings.id).\(actionID)",
                defaultValue: .unbound
            )
            if entry.wasPersisted {
                try? await jsonStore.set(entry.original, for: key)
            } else {
                try? await jsonStore.reset(key)
            }
        }
    }

    /// Removes legacy overrides only after the JSON rebase and its new prefix
    /// have both committed successfully. Keeping the old value until then
    /// makes a failed prefix write fully recoverable.
    private func finalizeLegacyRebasedChords(_ snapshot: RebasedChordSnapshot) async {
        for actionID in snapshot.migratedLegacyActionIDs {
            guard let action = ShortcutAction(rawValue: actionID) else { continue }
            await userDefaultsStore?.resetLegacyShortcutBinding(for: action)
            legacyBindings.removeValue(forKey: actionID)
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
