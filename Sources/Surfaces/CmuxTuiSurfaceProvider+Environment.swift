import Foundation

extension CmuxTuiSurfaceProvider {
    /// Delivers `entries` to the machine's `~/.config/cmux/env` over the link — see
    /// `CloudEnvDelivery` for the protocol and why no other channel is acceptable.
    /// Returns what the receiver reported; throws with the receiver's own reason when
    /// it refused, and with an "outdated shim" explanation when the machine does not
    /// know the verb yet.
    func deliverEnvironment(_ entries: [CloudEnvDelivery.Entry]) async throws -> CloudEnvDelivery.Outcome {
        let payload = try CloudEnvDelivery.payload(entries)
        let wire = CloudEnvDelivery.wire(payload)
        var receiver: SurfaceResource?
        return try await CloudEnvDelivery.withReceiverWorkspace(
            createWorkspace: { try await self.createEnvironmentReceiverWorkspace() },
            closeWorkspace: { try await self.removeEnvironmentReceiverWorkspace($0, receiver: receiver) },
            operation: { workspaceID in
                let created = try await self.createTerminal(
                    command: CloudEnvDelivery.receiverCommand,
                    cwd: nil,
                    name: CloudEnvDelivery.receiverTitle,
                    remoteWorkspaceID: workspaceID,
                    onExit: "keep"
                )
                receiver = created
                return try await self.deliverEnvironmentWire(wire, terminalID: created.id.key)
            }
        )
    }

    private func removeEnvironmentReceiverWorkspace(_ workspaceID: String, receiver: SurfaceResource?) async throws {
        try await CloudEnvDelivery.removeReceiverResources(
            terminalIDs: receiver.map { [$0.id.key] } ?? [],
            discoverTerminalIDs: {
                guard await self.refreshCurrentGraph(force: true) else {
                    throw CloudEnvDelivery.DeliveryError.workspaceCleanupFailed(workspaceID)
                }
                return self.catalog.snapshot.resources(on: self.machine).filter {
                    $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == workspaceID }
                }.map { $0.id.key }
            },
            closeTerminal: { terminalID in
                do {
                    try await self.closeTerminal(
                        SurfaceResourceID(machine: self.machine, kind: .terminal, key: terminalID),
                        fallbackTabID: receiver?.remoteViews?.first?.tabID
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

    private func createEnvironmentReceiverWorkspace() async throws -> String {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let result = try await link.run(arguments: CloudTuiCommandLine.createWorkspaceArguments(
            socketPath: connected.socketPath,
            name: "\(CloudEnvDelivery.receiverTitle) \(UUID().uuidString)",
            empty: true
        ))
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let workspaceID = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
            throw ProviderError.noWorkspaceOnMachine(machineID)
        }
        return workspaceID
    }

    private func deliverEnvironmentWire(_ wire: Data, terminalID: String) async throws -> CloudEnvDelivery.Outcome {
        let ready = try await waitForScreen(
            terminalID: terminalID,
            pattern: CloudEnvDelivery.readyMarker,
            timeoutMs: CloudEnvDelivery.readyTimeoutMs
        )
        try CloudEnvDelivery.requireReady(ready, machineID: machineID)
        // Echo is off on the receiver's PTY from here on; the daemon never journals
        // input, so the payload exists on the machine only inside the receiver.
        for chunk in CloudEnvDelivery.chunks(wire) {
            try await writeBytes(terminalID: terminalID, data: chunk)
        }
        let result = try await waitForScreen(
            terminalID: terminalID,
            pattern: CloudEnvDelivery.resultPattern,
            timeoutMs: CloudEnvDelivery.resultTimeoutMs
        )
        return try CloudEnvDelivery.requireOutcome(result)
    }

    /// ASCII receiver-wire bytes reach the terminal through stdin, never process argv.
    func writeBytes(terminalID: String, data: Data) async throws {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        _ = try await link.run(
            arguments: CloudTuiCommandLine.writeBytesArguments(socketPath: connected.socketPath, terminalID: terminalID),
            input: data
        )
    }
}
