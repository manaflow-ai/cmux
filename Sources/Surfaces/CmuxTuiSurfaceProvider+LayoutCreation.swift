import Foundation

extension CmuxTuiSurfaceProvider: SurfaceLayoutTerminalCreating {
    /// A shared refresh can reject an equal-cursor conflict while another
    /// reader is publishing the same generation. That rejection is not proof
    /// that the source tab is gone, so a layout mutation gets one direct
    /// operation snapshot before it fails.
    private func layoutGraph(nearTabID: String) async throws -> (
        state: CloudVMState,
        connected: CloudMachineLink.Connected,
        link: CloudMachineLink
    ) {
        if await refreshCurrentGraph(force: true),
           let state = cloudState,
           state.lookupIndex.tab(id: nearTabID) != nil,
           let connected = try? await links.connected(machineID: machineID),
           let link = await links.link(machineID: machineID) {
            return (state, connected, link)
        }

        let connected = try await links.connected(machineID: machineID)
        guard let link = await links.link(machineID: machineID) else {
            throw ProviderError.machineAsleep(machineID)
        }
        let data = try await link.run(
            arguments: CloudTuiCommandLine.snapshotArguments(socketPath: connected.socketPath)
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine),
              state.lookupIndex.tab(id: nearTabID) != nil else {
            throw ProviderError.remoteTabNotFound(nearTabID)
        }
        return (state, connected, link)
    }

    /// Uses the exact source view, not daemon focus, so a local split and the
    /// Cloud tree acquire the same pane/tab relationship in one remote mutation.
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource {
        let key = "cmux-cloud-create-\(UUID().uuidString.lowercased())"
        var retried = false
        while true {
            let graph = try await layoutGraph(nearTabID: nearTabID)
            let state = graph.state
            guard let tab = state.lookupIndex.tab(id: nearTabID),
                  let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else {
                throw ProviderError.remotePlacementUnavailable(nearTabID)
            }
            let connected = graph.connected
            let link = graph.link
            var arguments = ["--socket", connected.socketPath, "--json", "pane", pane.id]
            if let splitDirection { arguments += ["split", "--" + splitDirection.rawValue] }
            else { arguments.append("run") }
            arguments += ["--idempotency-key", key]
            if let cursor = state.cursor { arguments += ["--expected-revision", String(cursor.revision)] }
            if splitDirection == nil { arguments += ["--"] + CloudTuiCommandLine.defaultTerminalCommand }
            do {
                let data = try await link.run(arguments: arguments)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: object) else {
                    throw ProviderError.terminalNotCreated(nearTabID)
                }
                return recordCreatedTerminal(created, workspaceID: screen.workspaceID, name: nil, cwd: nil)
            } catch {
                guard !retried, Self.isRevisionConflict(error) else { throw error }
                retried = true
            }
        }
    }
}
