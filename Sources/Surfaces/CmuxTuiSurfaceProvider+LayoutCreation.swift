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
        let lifecycle = lifecycleGeneration
        try validateTerminalMutationLifecycle(lifecycle)
        return try await terminalMutationQueue.run {
            try await self.createTerminalInMutationTurn(
                nearTabID: nearTabID, splitDirection: splitDirection, request: request, lifecycle: lifecycle
            )
        }
    }

    private func createTerminalInMutationTurn(
        nearTabID: String,
        splitDirection: SurfaceSplitDirection?,
        request: CloudTerminalCreationRequest,
        lifecycle: UInt64
    ) async throws -> SurfaceResource {
        try validateTerminalMutationLifecycle(lifecycle)
        let connected = try await links.connected(machineID: machineID)
        try validateTerminalMutationLifecycle(lifecycle)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        try validateTerminalMutationLifecycle(lifecycle)
        let commands = CloudTerminalMutationCommandRunner(base: link) {
            try self.validateTerminalMutationLifecycle(lifecycle)
        }
        let recovered = try await request.prepare(using: commands, socketPath: connected.socketPath)
        try validateTerminalMutationLifecycle(lifecycle)
        if let created = recovered {
            guard let workspaceID = created.workspaceID else { throw ProviderError.invalidSnapshot(machineID) }
            return recordCreatedTerminal(created, workspaceID: workspaceID, name: nil, cwd: nil)
        }
        let result = try await CloudTerminalLayoutCreation(
            machine: machine,
            socketPath: connected.socketPath,
            commandRunner: commands,
            initialState: cloudState,
            terminalCommand: request.commandOverride ?? summary.defaultTerminalCommand
        ).run(
            nearTabID: nearTabID,
            splitDirection: splitDirection,
            idempotencyKey: request.attemptKey,
            correlationKey: request.correlationArgument,
            expectedWorkspaceID: request.remoteWorkspaceID
        )
        try validateTerminalMutationLifecycle(lifecycle)
        return recordCreatedTerminal(result.created, workspaceID: result.workspaceID, name: nil, cwd: nil)
    }
}
