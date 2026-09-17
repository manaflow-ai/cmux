import Foundation

extension CmuxTuiSurfaceProvider: SurfaceAgentNaming {
    /// Automatic names use the revision captured before the agent computed them.
    /// Refresh supplies current topology, but never upgrades that name precondition.
    func renameAgentTab(context: CloudAgentNameContext, name: String) async throws {
        let lifecycle = currentLifecycleGeneration
        guard context.projection.resource.machine == machine,
              await refreshCurrentGraph(force: true),
              let state = cloudState,
              CloudAgentNameContext(projection: context.projection, state: state) == context,
              let cursor = state.cursor, let tabID = context.projection.remoteTabID else {
            throw CancellationError()
        }
        let connected = try await links.connected(machineID: machineID)
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog(),
              let link = await links.link(machineID: machineID) else { throw CancellationError() }
        try Task.checkCancellation()
        let data = try await link.run(arguments: context.renameArguments(
            socketPath: connected.socketPath, name: name
        ))
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog(),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CancellationError()
        }
        let receipt = try validatedReceipt(CmuxTuiSnapshotParser.mutationCursor(fromResult: object), against: cursor)
        recordPendingRemoteRename(tabID: tabID, name: name, receipt: receipt)
        _ = await refreshCurrentGraph(force: true)
    }
}
