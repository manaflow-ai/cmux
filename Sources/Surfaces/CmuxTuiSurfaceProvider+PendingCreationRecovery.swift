import Foundation

/// Read-your-write overlays for Cloud terminal creation and rename receipts.
///
/// This extension owns the transient pending metadata used while the accepted
/// daemon graph catches up with a mutation response.
@MainActor
extension CmuxTuiSurfaceProvider {
    struct PendingRemoteCreation {
        var resource: SurfaceResource
        var receipt: CloudVMCursor?
        let tabID: String?
    }

    /// Merges pending mutation receipts into derived rows until an accepted
    /// graph reaches each receipt. The canonical graph is never edited here.
    /// A generation change, or a cursorless snapshot after a versioned receipt,
    /// retires the overlay because the old placement cannot be proven to exist.
    func resourcesWithPendingCreations(
        _ resources: [SurfaceResource],
        state: CloudVMState?
    ) -> [SurfaceResource] {
        var merged = resources
        var completed: [SurfaceResourceID] = []
        for (resourceID, pending) in pendingRemoteCreations where resourceID.machine == machine {
            if let state {
                if let receipt = pending.receipt {
                    guard let cursor = state.cursor,
                          cursor.generation == receipt.generation else {
                        completed.append(resourceID)
                        continue
                    }
                    if cursor.revision >= receipt.revision {
                        // At or beyond the commit, the accepted graph is the
                        // source of truth, including an intentional close.
                        completed.append(resourceID)
                        continue
                    }
                } else if pendingCreationIsVisible(pending, in: state) {
                    // Legacy mutation responses have no ordering fence. Stop
                    // overlaying as soon as the exact path is observed.
                    completed.append(resourceID)
                    continue
                }
            }
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

    func pendingCreation(forTabID tabID: String) -> PendingRemoteCreation? {
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
