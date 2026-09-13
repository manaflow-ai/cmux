import Foundation

/// Placement rename writes share the provider revision/receipt fence for user and agent calls.
extension CmuxTuiSurfaceProvider {
    /// Rename one placement-local daemon tab. This is the canonical path used by a
    /// cloud-tree workspace row and by a local pane that remembers its remote tab id.
    func renameRemoteTab(id: String, name: String) async throws {
        try await renameTab(id: id, name: name, expectedName: nil)
    }

    func renameRemoteTab(id: String, name: String, expectedName: String) async throws {
        try await renameTab(id: id, name: name, expectedName: expectedName)
    }

    private func renameTab(id: String, name: String, expectedName: String?) async throws {
        try Task.checkCancellation()
        let normalizedName = CloudRemoteRenameName(rawValue: name).wireValue

        // Creation and rename can arrive back-to-back. Refresh before validating the
        // target, but use the creation receipt when the accepted snapshot still
        // trails it. The receipt's revision is a CAS fence, not a timing guess.
        let refreshEstablishedCurrentGraph = await refreshCurrentGraph(force: true)
        try Task.checkCancellation()
        let pendingCreation = pendingCreation(forTabID: id)
        let pendingRename = pendingRemoteRename(for: .tab(id))
        let observed = cloudState
        let previous = observed?.tabs.first(where: { $0.id == id })
        let observedCursor = observed?.cursor
        if let expectedName {
            let currentName = pendingRename?.name ?? previous?.name
                ?? pendingCreation?.resource.remoteViews?.first(where: { $0.tabID == id })?.name ?? ""
            guard currentName == expectedName else { throw CancellationError() }
        }
        let pendingReceipt = [pendingCreation?.receipt, pendingRename?.receipt]
            .compactMap { $0 }
            .filter { receipt in
                guard let observedCursor else { return true }
                return receipt.generation == observedCursor.generation
            }
            .max { $0.revision < $1.revision }
        let authority = CloudVMRemoteMutationAuthority.resolve(
            refreshEstablishedCurrentGraph: refreshEstablishedCurrentGraph,
            hasAcceptedState: observed != nil,
            targetVisible: previous != nil,
            hasVersionedCursor: observedCursor != nil,
            hasPendingReceipt: pendingReceipt != nil
        )
        switch authority {
        case .currentGraph:
            guard let previous, let observedCursor else {
                throw ProviderError.stateUnavailable(machineID)
            }
            do {
                let receipt = try await sendRenameTab(
                    id: id,
                    name: normalizedName,
                    expectedRevision: observedCursor.revision
                )
                let validated = try validatedReceipt(receipt, against: observedCursor)
                recordPendingRemoteRename(tabID: id, name: normalizedName, receipt: validated)
                recordPendingRename(tabID: id, name: normalizedName, revision: validated.revision)
            } catch {
                guard Self.isRevisionConflict(error),
                      await refreshCurrentGraph(force: true),
                      let latest = cloudState,
                      let current = latest.tabs.first(where: { $0.id == id }),
                      let latestCursor = latest.cursor,
                      (current.name ?? "") == (previous.name ?? "") else { throw error }
                let receipt = try await sendRenameTab(
                    id: id,
                    name: normalizedName,
                    expectedRevision: latestCursor.revision
                )
                let validated = try validatedReceipt(receipt, against: latestCursor)
                recordPendingRemoteRename(tabID: id, name: normalizedName, receipt: validated)
                recordPendingRename(tabID: id, name: normalizedName, revision: validated.revision)
            }
        case .pendingReceipt:
            guard let receipt = pendingReceipt else {
                throw ProviderError.stateUnavailable(machineID)
            }
            let committed = try await sendRenameTab(
                id: id,
                name: normalizedName,
                expectedRevision: receipt.revision
            )
            let validated = try validatedReceipt(committed, against: receipt)
            recordPendingRemoteRename(tabID: id, name: normalizedName, receipt: validated)
            recordPendingRename(tabID: id, name: normalizedName, revision: validated.revision)
        case .snapshotOnly:
            throw ProviderError.snapshotOnly(machineID)
        case .unavailable:
            throw ProviderError.stateUnavailable(machineID)
        case .targetMissing:
            throw SurfaceCatalogError.unsupported(
                String(localized: "cloudTree.error.renameTerminalNoView", defaultValue: "This terminal is not open in a remote workspace.")
            )
        }
        // The daemon event normally installs this before the command exits. The
        // explicit read is the barrier for older clients that do not stream deltas.
        try Task.checkCancellation()
        _ = await refreshCurrentGraph(force: true)
    }

}
