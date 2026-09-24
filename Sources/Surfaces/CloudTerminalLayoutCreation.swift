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
    var initialState: CloudVMState? = nil
    var commandDeadline: Duration = .seconds(30)
    var terminalCommand: [String] = CloudTuiCommandLine.defaultTerminalCommand

    /// Reconciles rejected revisions within one operation deadline. Every attempt
    /// revalidates placement and retains the intent's idempotency key.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func run(
        nearTabID: String,
        splitDirection: SurfaceSplitDirection?,
        idempotencyKey: String = "cmux-cloud-create-\(UUID().uuidString.lowercased())",
        correlationKey: String? = nil,
        expectedWorkspaceID: String? = nil
    ) async throws -> CloudTerminalLayoutCreationResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: commandDeadline)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let snapshotBudget = clock.now.duration(to: deadline)
            guard snapshotBudget > .zero else { throw CloudDiagnosticFailure.timeout }
            let state: CloudVMState
            if attempt == 0, let initialState, initialState.cursor != nil,
               initialState.lookupIndex.tab(id: nearTabID) != nil { state = initialState }
            else { state = try await snapshot(deadline: snapshotBudget) }
            guard let tab = state.lookupIndex.tab(id: nearTabID),
                  tab.contentKind == "terminal" else {
                throw CmuxTuiSurfaceProvider.ProviderError.remoteTabNotFound(nearTabID)
            }
            guard let pane = state.lookupIndex.pane(id: tab.paneID),
                  let screen = state.lookupIndex.screen(id: pane.screenID) else {
                throw CmuxTuiSurfaceProvider.ProviderError.remotePlacementUnavailable(nearTabID)
            }
            // The revision fence protects this comparison through the mutation.
            // A conflict retry must recheck placement, never follow a moved tab.
            if let expectedWorkspaceID, screen.workspaceID != expectedWorkspaceID {
                throw CloudDiagnosticFailure.placement
            }
            let arguments = CloudTuiRequests.paneCreate(
                paneID: pane.id, direction: splitDirection?.rawValue,
                command: terminalCommand, revision: state.cursor?.revision,
                key: idempotencyKey, correlationKey: correlationKey
            )
            do {
                try Task.checkCancellation()
                let mutationBudget = clock.now.duration(to: deadline)
                guard mutationBudget > .zero else { throw CloudDiagnosticFailure.timeout }
                let data = try await commandRunner.runTuiCommand(arguments: arguments, deadline: mutationBudget)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let created = CmuxTuiSnapshotParser.createdTerminal(fromRunResult: object) else {
                    throw CmuxTuiSurfaceProvider.ProviderError.terminalNotCreated(nearTabID)
                }
                return CloudTerminalLayoutCreationResult(created: created, workspaceID: screen.workspaceID)
            } catch {
                guard CmuxTuiSurfaceProvider.isRevisionConflict(error),
                      attempt == 0 || Self.isConfirmedRevisionConflict(error) else { throw error }
                attempt += 1
            }
        }
    }

    /// Reads a complete graph without publishing unrelated provider state.
    private func snapshot(deadline: Duration) async throws -> CloudVMState {
        try await CloudOperationContext.phase(.snapshot) {
            let data = try await commandRunner.runTuiCommand(
                arguments: CloudTuiRequests.snapshotArguments(socketPath: socketPath),
                deadline: deadline
            )
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine) else {
                throw CmuxTuiSurfaceProvider.ProviderError.invalidSnapshot(machine.rawValue)
            }
            return state
        }
    }

    /// Older clients retain their single text-based retry. Additional retries
    /// require the daemon's structured proof that this mutation did not commit.
    private static func isConfirmedRevisionConflict(_ error: Error) -> Bool {
        guard let linkError = error as? CloudMachineLink.LinkError,
              case let .exited(_, output) = linkError else { return false }
        return output.split(whereSeparator: \.isNewline).contains { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return false
            }
            return object["code"] as? String == "revision.conflict"
        }
    }
}
