import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// The latest cloud terminal creation failure shown by its owning workspace.
public struct CloudPaneCreationFailure: Identifiable, Equatable {
    public let id: UUID
    public let machine: SurfaceMachineID
    public let sourcePanelID: UUID?
    public let title: String
    public let displayTitle: String
    public let errorText: String
    public let recoveryText: String
    public let diagnosticReference: String?

    /// Builds a privacy-safe, localized snapshot from a provider error.
    public init(machine: SurfaceMachineID, error: Error, title: String? = nil, recoveryText: String? = nil, context: CloudOperationContext? = nil, sourcePanelID: UUID? = nil) {
        id = UUID()
        self.machine = machine
        self.sourcePanelID = sourcePanelID
        let isSSH = machine.isSSH
        displayTitle = title ?? String(
            localized: isSSH ? "sshPane.newTerminalFailed.shortTitle" : "cloudPane.newTerminalFailed.shortTitle",
            defaultValue: isSSH ? "Couldn’t open SSH terminal" : "Couldn’t open terminal"
        )
        self.title = title ?? displayTitle
        errorText = Self.errorMessage(error, isSSH: isSSH)
        diagnosticReference = context.map {
            "operation=\($0.operationID.uuidString.lowercased()) trace=\($0.traceID)"
        }
        self.recoveryText = recoveryText ?? String(
            localized: isSSH ? "sshPane.newTerminalFailed.recovery" : "cloudPane.newTerminalFailed.recovery",
            defaultValue: isSSH ? "Check the SSH connection, then retry this request." : "Check that the machine is connected, then retry this request."
        )
    }

    /// The localized text copied from the card's context menu for troubleshooting.
    public var copyableText: String {
        [displayTitle, errorText, recoveryText, diagnosticReference].compactMap { $0 }.joined(separator: "\n")
    }

    /// Only known, structured errors may supply detail. A process response can
    /// contain terminal content or credentials, so never copy arbitrary error text.
    private static func errorMessage(_ error: Error, isSSH: Bool) -> String {
        guard isSSH else { return CloudDiagnosticFailure.classify(error).label }
        if let localized = error as? LocalizedError,
           let text = localized.errorDescription,
           !text.isEmpty {
            return text
        }
        let text = String(describing: error)
        return text.isEmpty ? "The SSH connection failed. Retry the connection." : text
    }
}
