import Foundation

extension CmuxTuiSurfaceProvider: SurfaceLayoutTerminalCreating {
    /// Uses the exact source view, not daemon focus, so a local split and the
    /// Cloud tree acquire the same pane/tab relationship in one remote mutation.
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource {
        try await createTerminal(
            nearTabID: nearTabID,
            splitDirection: splitDirection,
            request: CloudTerminalCreationRequest()
        )
    }

    /// Keeps the caller's idempotency identity through revision retries and
    /// explicit UI retries. A new key here can create a second remote terminal
    /// after the first mutation committed but its response was lost.
    func createTerminal(
        nearTabID: String,
        splitDirection: SurfaceSplitDirection?,
        request: CloudTerminalCreationRequest
    ) async throws -> SurfaceResource {
        var retried = false
        while true {
            guard await refreshCurrentGraph(force: true), let state = cloudState else {
                throw ProviderError.stateUnavailable(machineID)
            }
            guard let tab = state.lookupIndex.tab(id: nearTabID),
                  let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else {
                throw ProviderError.remoteTabNotFound(nearTabID)
            }
            let connected = try await links.connected(machineID: machineID)
            guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
            var arguments = ["--socket", connected.socketPath, "--json", "pane", pane.id]
            if let splitDirection { arguments += ["split", "--" + splitDirection.rawValue] }
            else { arguments.append("run") }
            arguments += ["--idempotency-key", request.attemptKey]
            if let correlationKey = request.correlationArgument {
                arguments += ["--correlation-key", correlationKey]
            }
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
