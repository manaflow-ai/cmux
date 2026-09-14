import Foundation

extension CmuxTuiSurfaceProvider: SurfaceLayoutTerminalCreating {
    /// Uses the exact source view, not daemon focus, so a local split and the
    /// Cloud tree acquire the same pane/tab relationship in one remote mutation.
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource {
        try await createTerminal(nearTabID: nearTabID, splitDirection: splitDirection, requestID: UUID())
    }

    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?, requestID: UUID) async throws -> SurfaceResource {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let result = try await CloudTerminalLayoutCreation(
            machine: machine,
            socketPath: connected.socketPath,
            commandRunner: link
        ).run(
            nearTabID: nearTabID,
            splitDirection: splitDirection,
            idempotencyKey: "cmux-cloud-create-\(requestID.uuidString.lowercased())"
        )
        return recordCreatedTerminal(result.created, workspaceID: result.workspaceID, name: nil, cwd: nil)
    }
}
