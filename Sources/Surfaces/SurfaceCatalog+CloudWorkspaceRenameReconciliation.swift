import Foundation

/// Catalog-owned state for reconciling cloud workspace rename receipts with
/// versioned snapshots. These values describe local read-your-write state and
/// must never be persisted as daemon truth.
@MainActor
final class CloudWorkspaceRenameReconciliationState {
    struct Key: Hashable, Sendable {
        let machine: SurfaceMachineID
        let workspaceID: String
    }

    struct Intent: Sendable {
        let sequence: UInt64
        let name: String
        let previousName: String
        var baselineCursor: CloudVMCursor?
        var receiptCursor: CloudVMCursor?
        var observedName: String?
        var observedCursor: CloudVMCursor?
    }

    struct Token: Hashable, Sendable {
        let key: Key
        let sequence: UInt64
        let previousName: String
        let baselineCursor: CloudVMCursor?
    }

    var cursors: [SurfaceMachineID: CloudVMCursor] = [:]
    /// Cursor of the graph represented by `fingerprints`. A mutation receipt can
    /// advance `cursors` before the corresponding graph arrives, so these are
    /// intentionally tracked separately.
    var graphCursors: [SurfaceMachineID: CloudVMCursor] = [:]
    var seenGenerations: [SurfaceMachineID: Set<String>] = [:]
    var fingerprints: [SurfaceMachineID: (cursor: CloudVMCursor, value: String)] = [:]
    var canonicalInfos: [SurfaceMachineID: SurfaceMachineInfo] = [:]
    var intents: [Key: Intent] = [:]
    var nextSequence: UInt64 = 0

    func remove(machine: SurfaceMachineID) {
        cursors[machine] = nil
        graphCursors[machine] = nil
        seenGenerations[machine] = nil
        fingerprints[machine] = nil
        canonicalInfos[machine] = nil
        intents = intents.filter { $0.key.machine != machine }
    }
}

extension SurfaceCatalog {
    /// The cursor used by the last accepted complete cloud graph or receipt.
    func cloudCursor(for machine: SurfaceMachineID) -> CloudVMCursor? {
        cloudWorkspaceRenameReconciliationState.cursors[machine]
    }

    /// Starts an optimistic rename against a stable machine/workspace identity.
    /// The returned token lets callers commit or roll back only their own edit.
    @discardableResult
    func beginCloudWorkspaceRename(
        machine: SurfaceMachineID,
        workspaceID: String,
        name: String
    ) throws -> CloudWorkspaceRenameReconciliationState.Token {
        guard case .cloud = machine else {
            throw SurfaceCatalogError.unsupported(String(
                localized: "cloudTree.error.renameLocalUnsupported",
                defaultValue: "Only cloud workspaces can be renamed through this path."
            ))
        }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SurfaceCatalogError.unsupported(String(
                localized: "cloudTree.error.renameWorkspaceEmpty",
                defaultValue: "A cloud workspace name cannot be empty."
            ))
        }

        let state = cloudWorkspaceRenameReconciliationState
        let key = CloudWorkspaceRenameReconciliationState.Key(machine: machine, workspaceID: workspaceID)
        // Every queued edit rolls back to the same canonical predecessor. Reading
        // the current optimistic label here would make two failed edits restore
        // the intermediate label instead of the daemon's last confirmed value.
        let previousName = state.intents[key]?.previousName
            ?? remoteWorkspaceName(machine: machine, workspaceID: workspaceID)
        guard let previousName else {
            throw SurfaceCatalogError.destinationNotFound(String(
                format: String(
                    localized: "cloudTree.error.renameWorkspaceMissing",
                    defaultValue: "workspace %@ on %@"
                ),
                workspaceID,
                machine.rawValue
            ))
        }

        state.nextSequence &+= 1
        let token = CloudWorkspaceRenameReconciliationState.Token(
            key: key,
            sequence: state.nextSequence,
            previousName: previousName,
            baselineCursor: state.cursors[machine]
        )
        state.intents[key] = CloudWorkspaceRenameReconciliationState.Intent(
            sequence: token.sequence,
            name: normalized,
            previousName: previousName,
            baselineCursor: token.baselineCursor,
            receiptCursor: nil,
            observedName: nil,
            observedCursor: nil
        )
        applyRemoteWorkspaceName(machine: machine, workspaceID: workspaceID, name: normalized)
        return token
    }

    /// Records the daemon cursor returned by a rename request while retaining
    /// the optimistic value until a complete graph confirms it.
    func commitCloudWorkspaceRename(
        _ token: CloudWorkspaceRenameReconciliationState.Token,
        receipt: CloudVMCursor?
    ) {
        let state = cloudWorkspaceRenameReconciliationState
        let acceptedReceipt: CloudVMCursor?
        if let receipt,
           let current = state.cursors[token.key.machine],
           current.generation == receipt.generation,
           receipt.revision >= current.revision {
            state.cursors[token.key.machine] = receipt
            // The receipt is ahead of the last accepted graph. Do not retain the
            // old equal-cursor fingerprint against the not-yet-arrived graph.
            state.fingerprints[token.key.machine] = nil
            acceptedReceipt = receipt
        } else {
            acceptedReceipt = nil
        }

        if let acceptedReceipt,
           var newer = state.intents[token.key],
           newer.sequence > token.sequence {
            // A queued local edit follows its predecessor's receipt, but an
            // unrelated remote revision never silently rebases it.
            newer.baselineCursor = acceptedReceipt
            newer.receiptCursor = nil
            newer.observedName = nil
            newer.observedCursor = nil
            state.intents[token.key] = newer
        }

        guard var intent = state.intents[token.key], intent.sequence == token.sequence else { return }
        intent.receiptCursor = acceptedReceipt
        intent.observedName = nil
        intent.observedCursor = nil
        state.intents[token.key] = intent
        applyRemoteWorkspaceName(
            machine: token.key.machine,
            workspaceID: token.key.workspaceID,
            name: intent.name
        )
    }

    /// Whether this token is still the newest local intent for its identity.
    func isCurrentCloudWorkspaceRename(_ token: CloudWorkspaceRenameReconciliationState.Token) -> Bool {
        cloudWorkspaceRenameReconciliationState.intents[token.key]?.sequence == token.sequence
    }

    /// Rolls back only the newest intent for an identity.
    func rollbackCloudWorkspaceRename(_ token: CloudWorkspaceRenameReconciliationState.Token) {
        let state = cloudWorkspaceRenameReconciliationState
        guard let intent = state.intents[token.key], intent.sequence == token.sequence else { return }
        state.intents[token.key] = nil
        applyRemoteWorkspaceName(
            machine: token.key.machine,
            workspaceID: token.key.workspaceID,
            name: intent.previousName
        )
    }

    /// Resolves an uncertain submission after the provider has performed a
    /// fresh read. Without an observed graph, the optimistic label stays visible.
    func resolveFailedCloudWorkspaceRename(_ token: CloudWorkspaceRenameReconciliationState.Token) {
        let state = cloudWorkspaceRenameReconciliationState
        guard let intent = state.intents[token.key], intent.sequence == token.sequence else { return }

        let name: String
        if let observedName = intent.observedName {
            name = observedName
        } else if intent.observedCursor != nil {
            // The fresh graph no longer contains the addressed workspace.
            name = intent.previousName
        } else if let current = state.cursors[token.key.machine],
                  let baseline = intent.receiptCursor ?? intent.baselineCursor,
                  current == baseline {
            // No accepted graph followed the submission; the CAS base is still
            // exactly the predecessor and rollback is safe.
            name = intent.previousName
        } else {
            return
        }

        state.intents[token.key] = nil
        applyRemoteWorkspaceName(
            machine: token.key.machine,
            workspaceID: token.key.workspaceID,
            name: name
        )
    }

    func pendingCloudWorkspaceRenameName(machine: SurfaceMachineID, workspaceID: String) -> String? {
        let key = CloudWorkspaceRenameReconciliationState.Key(machine: machine, workspaceID: workspaceID)
        return cloudWorkspaceRenameReconciliationState.intents[key]?.name
    }

    /// Returns the compare-and-swap cursor a rename token may submit against.
    func cloudWorkspaceRenameSubmissionCursor(
        _ token: CloudWorkspaceRenameReconciliationState.Token
    ) -> CloudVMCursor? {
        let state = cloudWorkspaceRenameReconciliationState
        guard let currentIntent = state.intents[token.key],
              currentIntent.sequence >= token.sequence else { return nil }
        let baseline = token.sequence == currentIntent.sequence
            ? (currentIntent.receiptCursor ?? currentIntent.baselineCursor)
            : token.baselineCursor
        guard let baseline, state.cursors[token.key.machine] == baseline else { return nil }
        return baseline
    }

    /// Broader than `isCurrent...`: an older operation remains live while a
    /// newer local operation waits for its receipt.
    func hasCloudWorkspaceRename(_ token: CloudWorkspaceRenameReconciliationState.Token) -> Bool {
        guard let intent = cloudWorkspaceRenameReconciliationState.intents[token.key] else { return false }
        return intent.sequence >= token.sequence
    }

    /// Installs a complete cloud graph with cursor and rename fences applied
    /// before any current resource rows are removed.
    @discardableResult
    func replaceCloudResources(
        _ list: [SurfaceResource],
        on machine: SurfaceMachineID,
        info: SurfaceMachineInfo,
        cursor: CloudVMCursor?,
        from source: (any SurfaceProvider)? = nil
    ) -> Bool {
        guard acceptsCloudWrite(machine: machine, from: source) else { return false }
        guard case .cloud = machine else {
            return replaceResources(list, on: machine, info: info, from: source)
        }

        let state = cloudWorkspaceRenameReconciliationState
        if let cursor {
            // A previously accepted generation is the only reliable evidence
            // that an opaque generation belongs to an old link after reconnect.
            if state.seenGenerations[machine]?.contains(cursor.generation) == true,
               state.cursors[machine]?.generation != cursor.generation {
                return false
            }
            if let current = state.cursors[machine], cursor.generation == current.generation {
                guard cursor.revision >= current.revision else { return false }
            }
        } else if state.cursors[machine] != nil {
            // A cursorless response cannot erase a versioned graph.
            return false
        }

        let incomingFingerprint = cloudWorkspaceGraphFingerprint(info: info, resources: list)
        if let cursor,
           let existing = state.fingerprints[machine],
           existing.cursor == cursor,
           existing.value != incomingFingerprint {
            return false
        }

        // A mutation receipt advances the cursor before the full snapshot may
        // arrive. At that cursor, the predecessor label is provably stale.
        if let cursor, state.fingerprints[machine] == nil {
            let receiptIntents = state.intents.filter {
                $0.key.machine == machine && $0.value.receiptCursor == cursor
            }
            for (key, intent) in receiptIntents {
                guard workspaceName(workspaceID: key.workspaceID, info: info, resources: list) == intent.name else {
                    return false
                }
            }
        }

        var mergedInfo = info
        var mergedResources = list
        reconcilePendingCloudWorkspaceRenames(
            machine: machine,
            cursor: cursor,
            info: &mergedInfo,
            resources: &mergedResources
        )
        let acceptedFingerprint = cloudWorkspaceGraphFingerprint(
            info: mergedInfo,
            resources: mergedResources
        )

        for resource in mergedResources {
            precondition(resource.machine == machine, "resource \(resource.id) reported by the wrong provider")
        }
        guard replaceResources(mergedResources, on: machine, info: mergedInfo, from: source) else {
            return false
        }
        state.canonicalInfos[machine] = mergedInfo
        if let cursor {
            state.cursors[machine] = cursor
            state.graphCursors[machine] = cursor
            state.seenGenerations[machine, default: []].insert(cursor.generation)
            state.fingerprints[machine] = (cursor: cursor, value: acceptedFingerprint)
        }
        return true
    }

    /// Keeps cursorless cloud metadata from regressing the last accepted
    /// workspace names, while allowing fresh status fields to update.
    func cloudWorkspaceRenameAdjustedInfo(_ info: SurfaceMachineInfo) -> SurfaceMachineInfo {
        guard case .cloud = info.id else { return info }
        let state = cloudWorkspaceRenameReconciliationState
        var adjusted = info
        if let canonical = state.canonicalInfos[info.id], canonical.remoteWorkspaces != nil {
            adjusted.remoteWorkspaces = canonical.remoteWorkspaces
        }
        for (key, intent) in state.intents where key.machine == info.id {
            adjusted.remoteWorkspaces = adjusted.remoteWorkspaces?.map { workspace in
                guard workspace.id == key.workspaceID else { return workspace }
                var renamed = workspace
                renamed.name = intent.name
                return renamed
            }
        }
        return adjusted
    }

    private func acceptsCloudWrite(
        machine: SurfaceMachineID,
        from source: (any SurfaceProvider)?
    ) -> Bool {
        guard machine.isLocal || provider(for: machine) != nil else { return false }
        guard let source else { return true }
        guard let registered = provider(for: machine), registered.machine == source.machine else { return false }
        return ObjectIdentifier(registered) == ObjectIdentifier(source)
    }

    private func remoteWorkspaceName(machine: SurfaceMachineID, workspaceID: String) -> String? {
        let current = snapshot
        let machineMatches = current.machines
            .first(where: { $0.id == machine })?.remoteWorkspaces?.filter { $0.id == workspaceID } ?? []
        if machineMatches.count > 1 { return nil }
        var names = Set(machineMatches.map(\.name))
        names.formUnion(current.resources(on: machine).flatMap { resource in
            resource.remoteWorkspaces.filter { $0.id == workspaceID }.map(\.name)
        })
        return names.count == 1 ? names.first : nil
    }

    private func applyRemoteWorkspaceName(machine: SurfaceMachineID, workspaceID: String, name: String) {
        let current = snapshot
        var adjustedInfo = current.machines.first(where: { $0.id == machine })
            ?? SurfaceMachineInfo(
                id: machine,
                name: machine.rawValue,
                status: "unknown",
                image: nil,
                hasDesktop: false,
                memoryMb: nil,
                diskMb: nil,
                linkState: .unavailable,
                linkError: nil,
                cpuPercent: nil,
                memoryUsedMb: nil,
                diskUsedMb: nil,
                remoteWorkspaces: nil
            )
        var adjustedResources = current.resources(on: machine)
        renameWorkspace(
            workspaceID: workspaceID,
            name: name,
            info: &adjustedInfo,
            resources: &adjustedResources
        )
        _ = replaceResources(adjustedResources, on: machine, info: adjustedInfo)
        cloudWorkspaceRenameReconciliationState.canonicalInfos[machine] = adjustedInfo
    }

    private func reconcilePendingCloudWorkspaceRenames(
        machine: SurfaceMachineID,
        cursor: CloudVMCursor?,
        info: inout SurfaceMachineInfo,
        resources: inout [SurfaceResource]
    ) {
        let state = cloudWorkspaceRenameReconciliationState
        let keys = Array(state.intents.keys.filter { $0.machine == machine })
        for key in keys {
            guard var intent = state.intents[key] else { continue }
            let incomingName = workspaceName(
                workspaceID: key.workspaceID,
                info: info,
                resources: resources
            )
            var overlay = true
            var clear = false
            if let cursor {
                // Save the raw observed graph before the optimistic overlay is
                // applied. This is used by uncertain-failure resolution.
                intent.observedName = incomingName
                intent.observedCursor = cursor
                state.intents[key] = intent
                let baseline = intent.receiptCursor ?? intent.baselineCursor
                if let baseline, cursor.generation == baseline.generation {
                    if incomingName == intent.name {
                        overlay = false
                        clear = true
                    } else if cursor.revision > baseline.revision {
                        // A newer writer won the race. Its value is authoritative.
                        overlay = false
                        clear = true
                    }
                } else if incomingName == intent.name {
                    // Different generations are not numerically comparable, but
                    // a matching name is unambiguous confirmation.
                    overlay = false
                    clear = true
                }
            }
            if overlay {
                renameWorkspace(
                    workspaceID: key.workspaceID,
                    name: intent.name,
                    info: &info,
                    resources: &resources
                )
            }
            if clear { state.intents[key] = nil }
        }
    }

    private func workspaceName(
        workspaceID: String,
        info: SurfaceMachineInfo,
        resources: [SurfaceResource]
    ) -> String? {
        let machineMatches = info.remoteWorkspaces?.filter { $0.id == workspaceID } ?? []
        if machineMatches.count > 1 { return nil }
        var names = Set(machineMatches.map(\.name))
        names.formUnion(resources.flatMap { resource in
            resource.remoteWorkspaces.filter { $0.id == workspaceID }.map(\.name)
        })
        return names.count == 1 ? names.first : nil
    }

    /// Encodes only the identity-bearing part of a cloud graph. Status, stats,
    /// and port discovery can change without advancing the daemon workspace cursor.
    private func cloudWorkspaceGraphFingerprint(
        info: SurfaceMachineInfo,
        resources: [SurfaceResource]
    ) -> String {
        var parts: [String] = []
        let workspaces = (info.remoteWorkspaces ?? []).sorted {
            $0.id != $1.id ? $0.id < $1.id : $0.index < $1.index
        }
        for workspace in workspaces {
            parts.append("w:\(workspace.id.count):\(workspace.id):\(workspace.name.count):\(workspace.name):\(workspace.index):\(workspace.focused ? 1 : 0)")
        }
        for resource in resources.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let views = (resource.remoteViews ?? []).sorted {
                $0.tabID != $1.tabID ? $0.tabID < $1.tabID : $0.workspace.id < $1.workspace.id
            }
            parts.append("r:\(resource.id.rawValue.count):\(resource.id.rawValue)")
            if let workspace = resource.remoteWorkspace {
                parts.append("p:\(workspace.id.count):\(workspace.id):\(workspace.name.count):\(workspace.name)")
            } else {
                parts.append("p:")
            }
            for view in views {
                parts.append("v:\(view.tabID.count):\(view.tabID):\(view.workspace.id.count):\(view.workspace.id):\(view.workspace.name.count):\(view.workspace.name)")
            }
        }
        return parts.joined(separator: "|")
    }

    private func renameWorkspace(
        workspaceID: String,
        name: String,
        info: inout SurfaceMachineInfo,
        resources: inout [SurfaceResource]
    ) {
        info.remoteWorkspaces = info.remoteWorkspaces?.map { workspace in
            guard workspace.id == workspaceID else { return workspace }
            var updated = workspace
            updated.name = name
            return updated
        }
        resources = resources.map { resource in
            var updated = resource
            if var workspace = updated.remoteWorkspace, workspace.id == workspaceID {
                workspace.name = name
                updated.remoteWorkspace = workspace
            }
            updated.remoteViews = updated.remoteViews?.map { view in
                guard view.workspace.id == workspaceID else { return view }
                var updatedView = view
                updatedView.workspace.name = name
                return updatedView
            }
            return updated
        }
    }
}
