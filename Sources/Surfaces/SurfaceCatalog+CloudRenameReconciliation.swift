import Foundation

/// Cursor state for the legacy versioned resource snapshot API. Current providers publish the
/// typed `CloudVMState`; this state only keeps older callers from regressing an accepted graph
/// while they migrate to that boundary.
struct CloudResourceCompatibilityState: Sendable {
    var cursor: CloudVMCursor
    var canonicalWorkspaces: [SurfaceRemoteWorkspace]
    var acceptedGenerations: Set<String>
}

struct CloudWorkspaceRenameKey: Hashable, Sendable {
    let machine: SurfaceMachineID
    let workspaceID: String
}

struct CloudWorkspaceRenameIntent: Sendable {
    let tokenID: UUID
    let baseName: String
    let name: String
    var receipt: CloudVMCursor?
}

struct CloudWorkspaceRenameRestoration: Sendable {
    let key: CloudWorkspaceRenameKey
    let baseName: String
}

struct CloudWorkspaceRenameToken: Hashable, Sendable {
    let id: UUID
    let key: CloudWorkspaceRenameKey
}

extension SurfaceCatalog {
    /// Keeps the accepted graph authoritative while retaining genuinely new pending rows.
    func machineInfoPreservingCanonicalCloudState(
        _ info: SurfaceMachineInfo,
        state: CloudVMState? = nil,
        restoringRename: CloudWorkspaceRenameRestoration? = nil
    ) -> SurfaceMachineInfo {
        guard case .cloud = info.id else { return info }
        guard let state = state ?? cloudStates[info.id] else {
            return cloudResourceCompatibilityMachineInfo(info, restoringRename: restoringRename)
        }
        var adjusted = info
        let canonical = cloudWorkspaceRenameEffectiveWorkspaces(state.workspaces.map {
            SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
        }, machine: info.id)
        var seen = Set(canonical.map(\.id))
        let pending = cloudWorkspaceRenameEffectiveWorkspaces(
            (info.remoteWorkspaces ?? []).filter { seen.insert($0.id).inserted },
            machine: info.id,
            restoringRename: restoringRename
        )
        adjusted.remoteWorkspaces = canonical + pending
        return adjusted
    }

    @discardableResult
    func clearCloudCompatibilityState(on machine: SurfaceMachineID) -> Bool {
        let hadState = cloudResourceCompatibility.removeValue(forKey: machine) != nil
        let hadIntents = cloudWorkspaceRenameIntents.contains { $0.key.machine == machine }
        cloudWorkspaceRenameIntents = cloudWorkspaceRenameIntents.filter { $0.key.machine != machine }
        return hadState || hadIntents
    }

    /// Replaces a cloud machine's legacy resource rows only when the cursor is current. Equal
    /// cursors are no-ops unless they carry the exact name covered by a read-your-write receipt;
    /// all other equal and older snapshots are stale.
    @discardableResult
    func replaceCloudResources(
        _ list: [SurfaceResource],
        on machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        cursor: CloudVMCursor,
        from source: (any SurfaceProvider)? = nil
    ) -> Bool {
        guard case .cloud = machine,
              info.id == machine,
              cloudStates[machine] == nil,
              accepts(writeFor: machine, from: source) else { return false }
        for resource in list {
            precondition(resource.machine == machine, "resource \(resource.id) reported by the wrong cloud machine")
        }
        guard acceptsCloudCompatibilitySnapshot(info: info, machine: machine, cursor: cursor) else {
            return false
        }

        let previous = cloudResourceCompatibility[machine]
        var generations = previous?.acceptedGenerations ?? []
        generations.insert(cursor.generation)
        cloudResourceCompatibility[machine] = CloudResourceCompatibilityState(
            cursor: cursor,
            canonicalWorkspaces: info.remoteWorkspaces ?? [],
            acceptedGenerations: generations
        )

        retireCloudWorkspaceRenameIntents(
            observed: info.remoteWorkspaces ?? [],
            cursor: cursor,
            machine: machine
        )
        let effectiveInfo = cloudResourceCompatibilityMachineInfo(info)
        let effectiveResources = cloudWorkspaceRenameEffectiveResources(list, machine: machine)
        return replaceResources(effectiveResources, on: machine, info: effectiveInfo, from: source)
    }

    /// Begins an optimistic workspace rename and returns a token that can later be committed or
    /// rolled back. Multiple tokens for one identity retain the original base name, so an older
    /// completion cannot undo a newer intent.
    func beginCloudWorkspaceRename(
        machine: SurfaceMachineID,
        workspaceID: String,
        name: String
    ) throws -> CloudWorkspaceRenameToken {
        guard case .cloud = machine,
              cloudResourceCompatibility[machine] != nil || cloudStates[machine] != nil,
              accepts(writeFor: machine) else { throw SurfaceCatalogError.noProvider(machine) }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw SurfaceCatalogError.unsupported(
                String(
                    localized: "cloudTree.error.renameWorkspaceEmptyName",
                    defaultValue: "A workspace name cannot be empty."
                )
            )
        }
        let key = CloudWorkspaceRenameKey(machine: machine, workspaceID: workspaceID)
        guard let machineInfo = snapshot.machines.first(where: { $0.id == machine }),
              let workspace = machineInfo.remoteWorkspaces?.first(where: { $0.id == workspaceID }) else {
            throw SurfaceCatalogError.unsupported(
                String(
                    localized: "cloudTree.error.renameWorkspaceNotFound",
                    defaultValue: "This remote workspace is no longer available."
                )
            )
        }
        let intents = cloudWorkspaceRenameIntents[key] ?? []
        let baseName = intents.first?.baseName ?? workspace.name
        let token = CloudWorkspaceRenameToken(id: UUID(), key: key)
        cloudWorkspaceRenameIntents[key, default: []].append(
            CloudWorkspaceRenameIntent(
                tokenID: token.id,
                baseName: baseName,
                name: normalizedName,
                receipt: nil
            )
        )
        applyCloudWorkspaceRenameOverlay(machine: machine)
        return token
    }

    /// Records the daemon's read-your-write cursor. The intent remains visible until an
    /// accepted snapshot reaches that cursor and proves the requested workspace name.
    func commitCloudWorkspaceRename(_ token: CloudWorkspaceRenameToken, receipt: CloudVMCursor) {
        guard var intents = cloudWorkspaceRenameIntents[token.key],
              let index = intents.firstIndex(where: { $0.tokenID == token.id }) else { return }
        intents[index].receipt = receipt
        cloudWorkspaceRenameIntents[token.key] = intents
    }

    /// Removes one optimistic intent. If a newer intent remains, its name stays projected; when
    /// the final intent is removed, the catalog returns to the accepted canonical workspace name.
    func rollbackCloudWorkspaceRename(_ token: CloudWorkspaceRenameToken) {
        guard var intents = cloudWorkspaceRenameIntents[token.key],
              let index = intents.firstIndex(where: { $0.tokenID == token.id }) else { return }
        let removedIntent = intents[index]
        let restoration = CloudWorkspaceRenameRestoration(key: token.key, baseName: removedIntent.baseName)
        intents.remove(at: index)
        if intents.isEmpty {
            cloudWorkspaceRenameIntents[token.key] = nil
        } else {
            cloudWorkspaceRenameIntents[token.key] = intents
        }
        applyCloudWorkspaceRenameOverlay(machine: token.key.machine, restoringRename: restoration)
    }

    func pendingCloudWorkspaceRenameName(machine: SurfaceMachineID, workspaceID: String) -> String? {
        cloudWorkspaceRenameIntents[
            CloudWorkspaceRenameKey(machine: machine, workspaceID: workspaceID)
        ]?.last?.name
    }

    /// Called by the existing cursorless machine-update path. It preserves the last accepted
    /// workspace graph while still exposing the newest local optimistic name.
    func cloudResourceCompatibilityMachineInfo(
        _ info: SurfaceMachineInfo,
        restoringRename: CloudWorkspaceRenameRestoration? = nil
    ) -> SurfaceMachineInfo {
        guard let state = cloudResourceCompatibility[info.id] else { return info }
        var adjusted = info
        let canonical = state.canonicalWorkspaces
        var seen = Set(canonical.map(\.id))
        let pending = (info.remoteWorkspaces ?? []).filter { seen.insert($0.id).inserted }
        adjusted.remoteWorkspaces = cloudWorkspaceRenameEffectiveWorkspaces(canonical, machine: info.id)
            + cloudWorkspaceRenameEffectiveWorkspaces(
                pending,
                machine: info.id,
                restoringRename: restoringRename
            )
        return adjusted
    }

    private func acceptsCloudCompatibilitySnapshot(
        info: SurfaceMachineInfo,
        machine: SurfaceMachineID,
        cursor: CloudVMCursor
    ) -> Bool {
        guard let current = cloudResourceCompatibility[machine] else { return true }
        if cursor.generation != current.cursor.generation {
            return !current.acceptedGenerations.contains(cursor.generation)
        }
        if cursor.revision < current.cursor.revision { return false }

        var matchedReceiptAtCursor = false
        for (key, intents) in cloudWorkspaceRenameIntents where key.machine == machine {
            for intent in intents {
                guard let receipt = intent.receipt, receipt.generation == cursor.generation else { continue }
                if cursor.revision < receipt.revision { return false }
                if cursor.revision == receipt.revision,
                   info.remoteWorkspaces?.first(where: { $0.id == key.workspaceID })?.name != intent.name {
                    return false
                }
                if cursor.revision == receipt.revision {
                    matchedReceiptAtCursor = true
                }
            }
        }
        if cursor.revision == current.cursor.revision,
           info.remoteWorkspaces == current.canonicalWorkspaces {
            return true
        }
        if cursor.revision > current.cursor.revision { return true }
        return matchedReceiptAtCursor
    }

    private func retireCloudWorkspaceRenameIntents(
        observed workspaces: [SurfaceRemoteWorkspace],
        cursor: CloudVMCursor,
        machine: SurfaceMachineID
    ) {
        for (key, intents) in cloudWorkspaceRenameIntents where key.machine == machine {
            let remaining = intents.filter { intent in
                guard let receipt = intent.receipt else { return true }
                // A newer cursor only proves the rename once this workspace is present in the
                // accepted graph. Pending rows can legitimately lag typed state across a cursor
                // or generation change, so keep the overlay until the workspace is observed.
                guard let observedName = workspaces.first(where: { $0.id == key.workspaceID })?.name else {
                    return true
                }
                if cursor.generation != receipt.generation { return false }
                if cursor.revision > receipt.revision { return false }
                if cursor.revision == receipt.revision && observedName == intent.name { return false }
                return true
            }
            cloudWorkspaceRenameIntents[key] = remaining.isEmpty ? nil : remaining
        }
    }

    func retireCloudWorkspaceRenameIntents(for state: CloudVMState) {
        guard let cursor = state.cursor else { return }
        retireCloudWorkspaceRenameIntents(
            observed: state.workspaces.map {
                SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
            },
            cursor: cursor,
            machine: state.machine
        )
    }

    private func applyCloudWorkspaceRenameOverlay(
        machine: SurfaceMachineID,
        restoringRename: CloudWorkspaceRenameRestoration? = nil
    ) {
        guard let info = snapshot.machines.first(where: { $0.id == machine }) else { return }
        let effectiveInfo = machineInfoPreservingCanonicalCloudState(
            info,
            restoringRename: restoringRename
        )
        let effectiveResources = cloudWorkspaceRenameEffectiveResources(
            snapshot.resources(on: machine),
            machine: machine,
            restoringRename: restoringRename
        )
        _ = replaceResources(effectiveResources, on: machine, info: effectiveInfo)
    }

    private func cloudWorkspaceRenameEffectiveWorkspaces(
        _ workspaces: [SurfaceRemoteWorkspace],
        machine: SurfaceMachineID,
        restoringRename: CloudWorkspaceRenameRestoration? = nil
    ) -> [SurfaceRemoteWorkspace] {
        workspaces.map { workspace in
            let key = CloudWorkspaceRenameKey(machine: machine, workspaceID: workspace.id)
            let name = cloudWorkspaceRenameIntents[key]?.last?.name
                ?? (cloudWorkspaceRenameIntents[key] == nil && restoringRename?.key == key
                    ? restoringRename?.baseName
                    : nil)
            guard let name else { return workspace }
            var adjusted = workspace
            adjusted.name = name
            return adjusted
        }
    }

    func cloudWorkspaceRenameEffectiveResources(
        _ resources: [SurfaceResource],
        machine: SurfaceMachineID,
        canonicalState: CloudVMState? = nil,
        restoringRename: CloudWorkspaceRenameRestoration? = nil
    ) -> [SurfaceResource] {
        let canonicalNames = cloudWorkspaceCanonicalNames(machine: machine, state: canonicalState)

        func effectiveName(for key: CloudWorkspaceRenameKey) -> String? {
            cloudWorkspaceRenameIntents[key]?.last?.name
                ?? canonicalNames[key.workspaceID]
                ?? (cloudWorkspaceRenameIntents[key] == nil && restoringRename?.key == key
                    ? restoringRename?.baseName
                    : nil)
        }

        return resources.map { resource in
            guard resource.machine == machine else { return resource }
            var adjusted = resource
            if let workspace = adjusted.remoteWorkspace {
                let key = CloudWorkspaceRenameKey(machine: machine, workspaceID: workspace.id)
                if let name = effectiveName(for: key) {
                    adjusted.remoteWorkspace?.name = name
                }
            }
            adjusted.remoteViews = adjusted.remoteViews?.map { view in
                let key = CloudWorkspaceRenameKey(machine: machine, workspaceID: view.workspace.id)
                guard let name = effectiveName(for: key) else { return view }
                var adjustedView = view
                adjustedView.workspace.name = name
                return adjustedView
            }
            return adjusted
        }
    }

    private func cloudWorkspaceCanonicalNames(
        machine: SurfaceMachineID,
        state: CloudVMState?
    ) -> [String: String] {
        if let state = state ?? cloudStates[machine] {
            return Dictionary(uniqueKeysWithValues: state.workspaces.map { ($0.id, $0.name) })
        }
        guard let compatibility = cloudResourceCompatibility[machine] else { return [:] }
        return Dictionary(uniqueKeysWithValues: compatibility.canonicalWorkspaces.map { ($0.id, $0.name) })
    }
}
