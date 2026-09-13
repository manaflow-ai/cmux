import Foundation

/// Read-your-write overlays and receipt fences for Cloud terminal creation.
///
/// This owner is separate from refresh orchestration so a delayed or restarted
/// daemon cannot erase an acknowledged terminal while the canonical graph catches up.
@MainActor
extension CmuxTuiSurfaceProvider {
    private static let pendingCreationGenerationRecoveryTimeout: TimeInterval = 120
    /// Merges pending mutation receipts into derived rows until an accepted
    /// graph reaches each receipt. The canonical graph is never edited here.
    /// A delayed snapshot cannot retire a receipt overlay. A generation change
    /// also leaves it in place until the exact terminal becomes visible again or
    /// the graph explicitly reports an exited/tombstoned terminal; a restart is
    /// a synchronization boundary, not evidence that a live create vanished.
    func resourcesWithPendingCreations(
        _ resources: [SurfaceResource],
        state: CloudVMState?
    ) -> [SurfaceResource] {
        var merged = resources
        var completed: [SurfaceResourceID] = []
        for (resourceID, var pending) in pendingRemoteCreations where resourceID.machine == machine {
            if let state {
                if let receipt = pending.receipt {
                    if let cursor = state.cursor, cursor.generation == receipt.generation,
                       cursor.revision >= receipt.revision {
                        // At or beyond the commit, the accepted graph is the
                        // source of truth, including an intentional close.
                        completed.append(resourceID)
                        continue
                    }
                    if state.cursor?.generation != receipt.generation {
                        // A daemon restart invalidates the old cursor, but not
                        // the remote operation. Keep the optimistic row until
                        // this terminal is observed in the new graph or an
                        // explicit lifecycle tombstone closes the operation.
                        if pendingCreationIsVisible(pending, in: state)
                            || pendingCreationIsExplicitlyEnded(pending, in: state) {
                            completed.append(resourceID)
                            continue
                        }
                        let now = Date()
                        if let since = pending.generationMismatchSince,
                           now.timeIntervalSince(since) >= Self.pendingCreationGenerationRecoveryTimeout {
                            completed.append(resourceID)
                            continue
                        }
                        pending.generationMismatchSince = pending.generationMismatchSince ?? now
                    }
                } else if pendingCreationIsVisible(pending, in: state) {
                    // Legacy mutation responses have no ordering fence. Stop
                    // overlaying as soon as the exact path is observed.
                    completed.append(resourceID)
                    continue
                }
            }
            pendingRemoteCreations[resourceID] = pending
            mergePendingCreation(pending, into: &merged)
        }
        for resourceID in completed {
            pendingRemoteCreations.removeValue(forKey: resourceID)
        }
        return merged
    }

    private func pendingCreationIsVisible(
        _ pending: PendingRemoteCreation,
        in state: CloudVMState
    ) -> Bool {
        guard state.lookupIndex.terminal(id: pending.resource.id.key) != nil else { return false }
        guard let tabID = pending.tabID else { return true }
        return state.lookupIndex.tab(id: tabID) != nil
    }

    private func pendingCreationIsExplicitlyEnded(
        _ pending: PendingRemoteCreation,
        in state: CloudVMState
    ) -> Bool {
        guard let terminal = state.lookupIndex.terminal(id: pending.resource.id.key) else { return false }
        return terminal.lifecycle == "exited" || terminal.lifecycle == "tombstoned"
    }

    private func mergePendingCreation(
        _ pending: PendingRemoteCreation,
        into resources: inout [SurfaceResource]
    ) {
        guard let pendingView = pending.resource.remoteViews?.first else {
            if !resources.contains(where: { $0.id == pending.resource.id }) {
                resources.append(pending.resource)
            }
            return
        }
        guard let index = resources.firstIndex(where: { $0.id == pending.resource.id }) else {
            resources.append(pending.resource)
            return
        }
        var resource = resources[index]
        var views = resource.remoteViews ?? []
        if !views.contains(where: { $0.tabID == pendingView.tabID }) {
            views.append(pendingView)
            resource.remoteViews = views
            if resource.remoteWorkspace == nil {
                resource.remoteWorkspace = pendingView.workspace
            }
        }
        resources[index] = resource
    }

    func remoteWorkspaces(for state: CloudVMState?) -> [SurfaceRemoteWorkspace]? {
        var result = state.map(Self.remoteWorkspaces) ?? info.remoteWorkspaces ?? []
        var seen = Set(result.map(\.id))
        for pending in pendingRemoteCreations.values {
            guard let workspace = pending.resource.remoteWorkspace,
                  seen.insert(workspace.id).inserted else { continue }
            result.append(workspace)
        }
        return result.isEmpty ? nil : result
    }

    func pendingMutationMetadata() -> [CloudVMPendingMutation] {
        var writes = pendingRemoteCreations.map { resourceID, pending in
            CloudVMPendingMutation(
                kind: .terminalCreate,
                resource: resourceID,
                remoteWorkspaceID: pending.resource.remoteWorkspace?.id,
                remoteTabID: pending.tabID,
                name: pending.resource.remoteViews?.first?.name,
                receipt: pending.receipt
            )
        }
        writes.append(contentsOf: pendingRemoteRenames.map { key, pending in
            switch key {
            case .workspace(let id):
                return CloudVMPendingMutation(
                    kind: .workspaceRename,
                    resource: nil,
                    remoteWorkspaceID: id,
                    remoteTabID: nil,
                    name: pending.name,
                    receipt: pending.receipt
                )
            case .tab(let id):
                return CloudVMPendingMutation(
                    kind: .tabRename,
                    resource: nil,
                    remoteWorkspaceID: nil,
                    remoteTabID: id,
                    name: pending.name,
                    receipt: pending.receipt
                )
            }
        })
        return writes.sorted { left, right in
            if left.kind.rawValue != right.kind.rawValue {
                return left.kind.rawValue < right.kind.rawValue
            }
            let leftID = left.resource?.rawValue ?? left.remoteWorkspaceID ?? left.remoteTabID ?? ""
            let rightID = right.resource?.rawValue ?? right.remoteWorkspaceID ?? right.remoteTabID ?? ""
            return leftID < rightID
        }
    }

    func observationWithPendingWrites(
        _ base: CloudVMStateObservation = .current
    ) -> CloudVMStateObservation {
        var observation = base
        let pending = pendingMutationMetadata()
        observation.pendingWrites = pending.isEmpty ? nil : pending
        return observation
    }

    func publishPendingMutationMetadata() {
        catalog.updateCloudPendingWrites(
            on: machine,
            writes: pendingMutationMetadata(),
            from: self
        )
    }

    func pendingCreation(for resourceID: SurfaceResourceID) -> PendingRemoteCreation? {
        pendingRemoteCreations[resourceID]
    }

    func pendingCreationReceipt(forTerminalID terminalID: String) -> CloudVMCursor? {
        pendingRemoteCreations.values.first { $0.resource.id.key == terminalID }?.receipt
    }

    func hasPendingCreation(forTerminalID terminalID: String) -> Bool {
        pendingRemoteCreations.values.contains { $0.resource.id.key == terminalID }
    }

    /// Returns true while the accepted graph is still behind a creation receipt.
    /// A detached result in this interval is a stale read, so attachment recovery
    /// must wait rather than projecting another remote tab.
    func pendingCreationAwaitingCurrentReceipt(forTerminalID terminalID: String) -> Bool {
        guard let receipt = pendingCreationReceipt(forTerminalID: terminalID) else { return false }
        guard let cursor = cloudState?.cursor else { return true }
        return cursor.generation == receipt.generation && cursor.revision < receipt.revision
    }

    private func pendingCreation(forTabID tabID: String) -> PendingRemoteCreation? {
        pendingRemoteCreations.values.first { $0.tabID == tabID }
    }

    /// Advances a pending receipt after a follow-up rename commits before the
    /// creation snapshot arrives. This keeps the optimistic row and its tab
    /// label coherent without inventing a second canonical graph.
    func recordPendingRename(tabID: String, name: String, revision: UInt64) {
        for resourceID in Array(pendingRemoteCreations.keys) {
            guard var pending = pendingRemoteCreations[resourceID], pending.tabID == tabID else { continue }
            if let receipt = pending.receipt {
                guard revision >= receipt.revision else { continue }
                pending.receipt = CloudVMCursor(generation: receipt.generation, revision: revision)
            }
            if var views = pending.resource.remoteViews,
               let viewIndex = views.firstIndex(where: { $0.tabID == tabID }) {
                views[viewIndex].name = name
                pending.resource.remoteViews = views
            }
            pendingRemoteCreations[resourceID] = pending
        }
        publishPendingMutationMetadata()
    }

}
