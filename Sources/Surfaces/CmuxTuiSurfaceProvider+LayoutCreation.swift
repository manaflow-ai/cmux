import Foundation

extension CmuxTuiSurfaceProvider: SurfaceLayoutTerminalCreating {
    /// Uses the exact source view, not daemon focus, so a local split and the
    /// Cloud tree acquire the same pane/tab relationship in one remote mutation.
    func createTerminal(nearTabID: String, splitDirection: SurfaceSplitDirection?) async throws -> SurfaceResource {
        let intentID = UUID().uuidString.lowercased()
        let key = "cmux-cloud-create-\(intentID)"
        let correlationKey = "cmux-cloud-terminal-\(intentID)"
        var retried = false
        while true {
            guard await refreshCurrentGraph(force: true), let state = cloudState,
                  let tab = state.lookupIndex.tab(id: nearTabID),
                  let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else {
                throw ProviderError.noWorkspaceOnMachine(machineID)
            }
            let connected = try await links.connected(machineID: machineID)
            guard let link = await links.link(machineID: machineID) else { throw ProviderError.machineAsleep(machineID) }
            let attemptArguments: CloudTuiCreationCoordinator.AttemptArguments = { attemptKey in
                var arguments = ["--socket", connected.socketPath, "--json", "pane", pane.id]
                if let splitDirection { arguments += ["split", "--" + splitDirection.rawValue] }
                else { arguments.append("run") }
                arguments += ["--idempotency-key", attemptKey, "--correlation-key", correlationKey]
                if let cursor = state.cursor { arguments += ["--expected-revision", String(cursor.revision)] }
                if splitDirection == nil { arguments += ["--"] + CloudTuiCommandLine.defaultTerminalCommand }
                return arguments
            }
            do {
                let coordinator = CloudTuiCreationCoordinator(
                    commandRunner: link,
                    socketPath: connected.socketPath,
                    workspaceID: screen.workspaceID,
                    command: CloudTuiCommandLine.defaultTerminalCommand,
                    onExit: nil,
                    correlationKey: correlationKey,
                    idempotencyKey: key,
                    attemptArguments: attemptArguments,
                    clock: attachmentClock
                )
                let created = try await coordinator.run()
                return recordCreatedTerminal(created, workspaceID: screen.workspaceID, name: nil, cwd: nil)
            } catch {
                guard !retried, Self.isRevisionConflict(error) else { throw error }
                retried = true
            }
        }
    }
}
