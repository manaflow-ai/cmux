import Foundation

extension CmuxTuiSurfaceProvider: SurfaceLayoutTerminalCreating {
    /// Uses the exact source view, not daemon focus, so a local split and the
    /// Cloud tree acquire the same pane/tab relationship in one remote mutation.
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource {
        try await createTerminal(nearTabID: nearTabID, splitDirection: splitDirection, request: CloudTerminalCreationRequest())
    }

    /// Keeps the caller's idempotency identity through revision retries and
    /// explicit UI retries so a lost response cannot create a second terminal.
    func createTerminal(
        nearTabID: String,
        splitDirection: SurfaceSplitDirection?,
        request: CloudTerminalCreationRequest
    ) async throws -> SurfaceResource {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        if let created = try await request.prepare(using: link, socketPath: connected.socketPath) {
            guard let workspaceID = created.workspaceID else { throw ProviderError.invalidSnapshot(machineID) }
            return recordCreatedTerminal(created, workspaceID: workspaceID, name: nil, cwd: nil)
        }
        let result = try await CloudTerminalLayoutCreation(
            machine: machine,
            socketPath: connected.socketPath,
            commandRunner: link,
            initialState: cloudState
        ).run(
            nearTabID: nearTabID,
            splitDirection: splitDirection,
            idempotencyKey: request.attemptKey,
            correlationKey: request.correlationArgument,
            expectedWorkspaceID: request.remoteWorkspaceID
        )
        return recordCreatedTerminal(result.created, workspaceID: result.workspaceID, name: nil, cwd: nil)
    }
}
