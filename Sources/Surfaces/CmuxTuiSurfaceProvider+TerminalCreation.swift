import CmuxSurfaceCatalogModel
import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    /// A new terminal in the machine's cmux-tui session (`workspace <ws> run -- argv`).
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        try await createTerminal(command: command, cwd: cwd, name: name, remoteWorkspaceID: remoteWorkspaceID, request: CloudTerminalCreationRequest())
    }

    /// Keeps one daemon mutation identity across explicit retries of the same request.
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?, request: CloudTerminalCreationRequest) async throws -> SurfaceResource {
        try await createTerminal(command: command, cwd: cwd, name: name, remoteWorkspaceID: remoteWorkspaceID, onExit: nil, request: request)
    }

    /// The same, choosing the daemon's exit policy: `"keep"` retains the tab and final
    /// screen after the process exits (a sender that reads the process's last lines as
    /// its result needs that); nil is the daemon default, `close`.
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?, onExit: String?) async throws -> SurfaceResource {
        try await createTerminal(command: command, cwd: cwd, name: name, remoteWorkspaceID: remoteWorkspaceID, onExit: onExit, request: CloudTerminalCreationRequest())
    }

    private func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?, onExit: String?, request: CloudTerminalCreationRequest) async throws -> SurfaceResource {
        let lifecycle = lifecycleGeneration
        try validateTerminalMutationLifecycle(lifecycle)
        return try await terminalMutationQueue.run {
            try await self.createTerminalInMutationTurn(
                command: command, cwd: cwd, name: name, remoteWorkspaceID: remoteWorkspaceID,
                onExit: onExit, request: request, lifecycle: lifecycle
            )
        }
    }

    private func createTerminalInMutationTurn(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?, onExit: String?, request: CloudTerminalCreationRequest, lifecycle: UInt64) async throws -> SurfaceResource {
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
            return recordCreatedTerminal(created, workspaceID: workspaceID, name: name, cwd: cwd)
        }
        // Resolve the active workspace inside the daemon mutation. A stale Mac
        // catalog must never bootstrap a second workspace during concurrent creates.
        let requestedWorkspace = remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = requestedWorkspace.flatMap { $0.isEmpty ? nil : $0 } ?? "current"
        // The protocol has a native cwd field. A shell wrapper would load
        // another login profile before executing the requested terminal.
        let argv = (command?.isEmpty == false ? command : nil) ?? request.commandOverride ?? summary.defaultTerminalCommand
        let data = try await commands.runTuiCommand(arguments: CloudTuiRequests.runArguments(
            socketPath: connected.socketPath, workspaceID: workspaceID, command: argv,
            onExit: onExit, cwd: cwd, idempotencyKey: request.attemptKey, correlationKey: request.correlationArgument
        ), deadline: .seconds(30))
        try validateTerminalMutationLifecycle(lifecycle)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: object) else {
            throw ProviderError.terminalNotCreated(String(data: data, encoding: .utf8) ?? "")
        }
        guard let resolvedWorkspaceID = created.workspaceID ?? (workspaceID == "current" ? nil : workspaceID) else {
            throw ProviderError.noWorkspaceOnMachine(machineID)
        }
        return recordCreatedTerminal(created, workspaceID: resolvedWorkspaceID, name: name, cwd: cwd)
    }

    /// The captured turn cannot survive suspension, retirement, or provider replacement.
    func validateTerminalMutationLifecycle(_ lifecycle: UInt64) throws {
        try Task.checkCancellation()
        guard isCurrentLifecycleGeneration(lifecycle), isRegisteredInCatalog() else {
            throw CancellationError()
        }
    }
}
