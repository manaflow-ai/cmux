import Foundation

/// Creates one terminal beside an exact daemon tab from a fresh operation snapshot.
///
/// Terminal creation must not wait for the provider's metrics, port scan, or
/// attachment-recovery pass. This operation reads only the graph needed to
/// authorize its mutation and retains the daemon's revision fence.
struct CloudTerminalLayoutCreation: Sendable {
    let machine: SurfaceMachineID
    let socketPath: String
    let commandRunner: any CloudTuiCommandRunning
    var commandDeadline: Duration = .seconds(30)

    /// Performs one create, retrying only a revision conflict that did not commit.
    /// The same idempotency key fences both attempts against duplicate terminals.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func run(
        nearTabID: String,
        splitDirection: SurfaceSplitDirection?,
        idempotencyKey: String = "cmux-cloud-create-\(UUID().uuidString.lowercased())",
        correlationKey: String? = nil
    ) async throws -> CloudTerminalLayoutCreationResult {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let state = try await snapshot()
            guard let tab = state.lookupIndex.tab(id: nearTabID),
                  tab.contentKind == "terminal" else {
                throw CmuxTuiSurfaceProvider.ProviderError.remoteTabNotFound(nearTabID)
            }
            guard let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else {
                throw CmuxTuiSurfaceProvider.ProviderError.remotePlacementUnavailable(nearTabID)
            }
            var arguments = ["--socket", socketPath, "--json", "pane", pane.id]
            if let splitDirection { arguments += ["split", "--" + splitDirection.rawValue] }
            else { arguments.append("run") }
            arguments += ["--idempotency-key", idempotencyKey]
            if let correlationKey { arguments += ["--correlation-key", correlationKey] }
            if let cursor = state.cursor { arguments += ["--expected-revision", String(cursor.revision)] }
            if splitDirection == nil { arguments += ["--"] + CloudTuiCommandLine.defaultTerminalCommand }
            do {
                try Task.checkCancellation()
                let data = try await commandRunner.runTuiCommand(arguments: arguments, deadline: commandDeadline)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: object) else {
                    throw CmuxTuiSurfaceProvider.ProviderError.terminalNotCreated(nearTabID)
                }
                return CloudTerminalLayoutCreationResult(created: created, workspaceID: screen.workspaceID)
            } catch {
                guard attempt == 0, CmuxTuiSurfaceProvider.isRevisionConflict(error) else { throw error }
                attempt += 1
            }
        }
    }

    /// Reads a complete graph without publishing unrelated provider state.
    private func snapshot() async throws -> CloudVMState {
        try await CloudOperationContext.phase(.snapshot) {
            let data = try await commandRunner.runTuiCommand(
                arguments: CloudTuiCommandLine.snapshotArguments(socketPath: socketPath),
                deadline: commandDeadline
            )
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine) else {
                throw CmuxTuiSurfaceProvider.ProviderError.invalidSnapshot(machine.rawValue)
            }
            return state
        }
    }
}
