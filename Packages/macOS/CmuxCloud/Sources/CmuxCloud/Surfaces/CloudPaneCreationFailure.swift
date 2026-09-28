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
        displayTitle = title ?? String(localized: "cloudPane.newTerminalFailed.shortTitle", defaultValue: "Couldn’t open terminal")
        self.title = title ?? displayTitle
        errorText = Self.errorMessage(error)
        diagnosticReference = context.map {
            "operation=\($0.operationID.uuidString.lowercased()) trace=\($0.traceID)"
        }
        self.recoveryText = recoveryText ?? String(
            localized: "cloudPane.newTerminalFailed.recovery",
            defaultValue: "Check that the machine is connected, then retry this request."
        )
    }

    /// The localized text copied from the card's context menu for troubleshooting.
    public var copyableText: String {
        [displayTitle, errorText, recoveryText, diagnosticReference].compactMap { $0 }.joined(separator: "\n")
    }

    /// Only known, structured errors may supply detail. A process response can
    /// contain terminal content or credentials, so never copy arbitrary error text.
    private static func errorMessage(_ error: Error) -> String {
        return CloudDiagnosticFailure.classify(error).label
    }
}
