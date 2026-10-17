import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// Removal of link-delivery receiver workspaces (`cmux env receive`, `cmux file
/// receive`): the one path both deliveries close their own receiver through, and the
/// sweep that closes receivers an earlier delivery leaked (the app quit or the link
/// dropped before its cleanup landed). Readers hide receiver workspaces
/// (``SurfaceRemoteWorkspace/isInternalReceiver``), so nothing else would remove them.
extension CmuxTuiSurfaceProvider {
    /// Closes a receiver workspace and its terminals. With no known terminal ids the
    /// graph is refreshed and the workspace's terminals are read from the raw rows;
    /// `cleanupFailed` is thrown when that refresh fails. A terminal or workspace
    /// that is already gone counts as closed.
    func removeReceiverWorkspace(
        _ workspaceID: String,
        terminalIDs: [String],
        cleanupFailed: @escaping @MainActor () -> Error
    ) async throws {
        try await CloudEnvDelivery.removeReceiverResources(
            terminalIDs: terminalIDs,
            discoverTerminalIDs: {
                guard await self.refreshCurrentGraph(force: true) else { throw cleanupFailed() }
                return self.receiverTerminalIDs(in: workspaceID)
            },
            closeTerminal: { terminalID in
                do {
                    try await self.closeTerminal(
                        SurfaceResourceID(machine: self.machine, kind: .terminal, key: terminalID)
                    )
                } catch {
                    guard Self.isSelectorNotFound(error) else { throw error }
                }
            },
            closeWorkspace: {
                do {
                    try await self.closeRemoteWorkspace(id: workspaceID)
                } catch {
                    guard Self.isSelectorNotFound(error) else { throw error }
                }
            }
        )
    }

    /// The terminals in `workspaceID`, from the raw rows: the catalog snapshot hides
    /// receiver workspaces.
    private func receiverTerminalIDs(in workspaceID: String) -> [String] {
        catalog.resources.values.filter {
            $0.machine == machine
                && $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == workspaceID }
        }.map { $0.id.key }
    }

    /// Runs ``sweepLeakedReceiverWorkspaces()`` after a link connects.
    func scheduleLeakedReceiverSweep() {
        Task { @MainActor [weak self] in
            await self?.sweepLeakedReceiverWorkspaces()
        }
    }

    /// Closes every receiver workspace on the machine when this Mac has no delivery
    /// of its own in flight (``SurfaceRemoteWorkspace/leakedInternalReceiverIDs(in:deliveriesInFlight:clientID:)``).
    /// Best effort: a failure leaves the rest for the next connect.
    func sweepLeakedReceiverWorkspaces() async {
        guard receiverDeliveriesInFlight == 0, await refreshCurrentGraph(force: true) else { return }
        let workspaces = cloudState.map(Self.remoteWorkspaces) ?? []
        // A delivery may have started while the graph was read.
        let leaked = SurfaceRemoteWorkspace.leakedInternalReceiverIDs(
            in: workspaces,
            deliveriesInFlight: receiverDeliveriesInFlight,
            clientID: receiverClientID
        )
        // A delivery that starts from here on creates a workspace not in `leaked`.
        for workspaceID in leaked {
            do {
                try await removeReceiverWorkspace(workspaceID, terminalIDs: receiverTerminalIDs(in: workspaceID)) {
                    CloudEnvDelivery.DeliveryError.workspaceCleanupFailed(workspaceID)
                }
            } catch {
#if DEBUG
                cmuxDebugLog("cloud.provider.receiverSweep.failed machine=\(machineID) error=\(type(of: error))")
#endif
                return
            }
        }
    }
}
