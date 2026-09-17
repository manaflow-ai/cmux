import Foundation

extension CmuxTuiSurfaceProvider {
    /// Delivers one file to the machine over the link — see `CloudFileDelivery` for the
    /// protocol and why `vm.exec` is not an option for a secret. Returns what the
    /// receiver reported; throws with the receiver's own reason when it refused, and
    /// with an "outdated shim" explanation when the machine does not know the verb yet.
    ///
    /// Mirrors `deliverEnvironment`: the receiver runs in a temporary, empty workspace
    /// of its own (so no user workspace gains a stray tab), with `--on-exit keep` so its
    /// verdict line survives the process exit, and the terminal and workspace are removed
    /// afterwards whatever happened.
    func deliverFile(_ request: CloudFileDelivery.Request) async throws -> CloudFileDelivery.Outcome {
        try CloudFileDelivery.validate(request)
        let wire = CloudFileDelivery.wire(request.data)
        var receiver: SurfaceResource?
        return try await CloudFileDelivery.withReceiverWorkspace(
            createWorkspace: { try await self.createFileReceiverWorkspace() },
            closeWorkspace: { try await self.removeFileReceiverWorkspace($0, receiver: receiver) },
            operation: { workspaceID in
                let created = try await self.createTerminal(
                    command: CloudFileDelivery.receiverCommand(path: request.path, mode: request.mode),
                    cwd: nil,
                    name: CloudFileDelivery.receiverTitle,
                    remoteWorkspaceID: workspaceID,
                    onExit: "keep"
                )
                receiver = created
                return try await self.deliverFileWire(wire, terminalID: created.id.key, expectedBytes: request.data.count)
            }
        )
    }

    private func createFileReceiverWorkspace() async throws -> String {
        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
        let result = try await link.run(arguments: CloudTuiCommandLine.createWorkspaceArguments(
            socketPath: connected.socketPath,
            name: "\(CloudFileDelivery.receiverTitle) \(UUID().uuidString)",
            empty: true
        ))
        guard let object = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let workspaceID = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
            throw ProviderError.noWorkspaceOnMachine(machineID)
        }
        return workspaceID
    }

    private func removeFileReceiverWorkspace(_ workspaceID: String, receiver: SurfaceResource?) async throws {
        try await CloudEnvDelivery.removeReceiverResources(
            terminalIDs: receiver.map { [$0.id.key] } ?? [],
            discoverTerminalIDs: {
                guard await self.refreshCurrentGraph(force: true) else {
                    throw CloudFileDelivery.DeliveryError.workspaceCleanupFailed(workspaceID)
                }
                return self.catalog.snapshot.resources(on: self.machine).filter {
                    $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == workspaceID }
                }.map { $0.id.key }
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

    private func deliverFileWire(_ wire: Data, terminalID: String, expectedBytes: Int) async throws -> CloudFileDelivery.Outcome {
        let ready = try await waitForScreen(
            terminalID: terminalID,
            pattern: CloudFileDelivery.readyMarker,
            timeoutMs: CloudFileDelivery.readyTimeoutMs
        )
        try CloudFileDelivery.requireReady(ready, machineID: machineID)
        // Echo is off on the receiver's PTY from here on; the daemon never journals
        // input, so the bytes exist on the machine only inside the receiver.
        for chunk in CloudEnvDelivery.chunks(wire) {
            try await writeBytes(terminalID: terminalID, data: chunk)
        }
        let result = try await waitForScreen(
            terminalID: terminalID,
            pattern: CloudFileDelivery.resultPattern,
            timeoutMs: CloudFileDelivery.resultTimeoutMs
        )
        return try CloudFileDelivery.requireOutcome(result, expectedBytes: expectedBytes)
    }
}
