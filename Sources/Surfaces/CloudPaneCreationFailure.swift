import Foundation

/// The latest cloud terminal creation failure shown by its owning workspace.
struct CloudPaneCreationFailure: Identifiable, Equatable {
    let id: UUID
    let machine: SurfaceMachineID
    let title: String
    let errorText: String
    let recoveryText: String
    let diagnosticReference: String?

    /// Builds a privacy-safe, localized snapshot from a provider error.
    init(machine: SurfaceMachineID, error: Error, context: CloudOperationContext? = nil) {
        id = UUID()
        self.machine = machine
        title = String(
            format: String(
                localized: "cloudPane.newTerminalFailed.title",
                defaultValue: "Couldn’t start a terminal on %@"
            ),
            machine.rawValue
        )
        errorText = Self.errorMessage(error)
        diagnosticReference = context.map {
            "operation=\($0.operationID.uuidString.lowercased()) trace=\($0.traceID)"
        }
        recoveryText = String(
            localized: "cloudPane.newTerminalFailed.recovery",
            defaultValue: "Check that the machine is connected, then try Cmd+D or Cmd+T again."
        )
    }

    /// The localized text copied from the card's context menu for troubleshooting.
    var copyableText: String {
        [title, errorText, recoveryText, diagnosticReference].compactMap { $0 }.joined(separator: "\n")
    }

    /// Only known, structured errors may supply detail. A process response can
    /// contain terminal content or credentials, so never copy arbitrary error text.
    private static func errorMessage(_ error: Error) -> String {
        if let error = error as? CmuxTuiSurfaceProvider.ProviderError {
            switch error {
            case .remoteWorkspaceNotFound, .remotePlacementUnavailable, .remoteTabNotFound,
                 .terminalExited, .terminalAttachTimedOut:
                if let message = error.errorDescription { return message }
            case .noWorkspaceOnMachine:
                return String(localized: "cloudPane.newTerminalFailed.noWorkspace", defaultValue: "This machine has no available workspace. Refresh the machine and try again.")
            case .stateUnavailable:
                return String(localized: "cloudPane.newTerminalFailed.stateUnavailable", defaultValue: "The machine’s current state could not be loaded. Reconnect and try again.")
            case .terminalNotCreated:
                return String(localized: "cloudPane.newTerminalFailed.invalidResult", defaultValue: "The machine did not return the new terminal. Refresh the machine before trying again.")
            default: break
            }
        }
        if let error = error as? SurfaceCatalogError, case .ambiguousRemotePlacement = error {
            return error.localizedDescription
        }
        return CloudDiagnosticFailure.classify(error).label
    }
}
