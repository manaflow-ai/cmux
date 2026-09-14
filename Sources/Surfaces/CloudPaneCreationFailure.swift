import Foundation

/// The latest cloud terminal creation failure shown by its owning workspace.
struct CloudPaneCreationFailure: Identifiable, Equatable {
    let id: UUID
    let machine: SurfaceMachineID
    let title: String
    let errorText: String
    let recoveryText: String

    /// Builds a privacy-safe, localized snapshot from a provider error.
    init(machine: SurfaceMachineID, error: Error) {
        id = UUID()
        self.machine = machine
        title = String(
            format: String(
                localized: "cloudPane.newTerminalFailed.title",
                defaultValue: "Couldn’t start a terminal on %@"
            ),
            machine.rawValue
        )
        let diagnostic = CloudDiagnosticFailure.classify(error)
        errorText = diagnostic == .unknown
            ? String(localized: "cloudPane.newTerminalFailed.unknownError", defaultValue: "The machine returned an unknown error.")
            : diagnostic.label
        recoveryText = String(
            localized: "cloudPane.newTerminalFailed.recovery",
            defaultValue: "Check that the machine is connected, then try Cmd+D or Cmd+T again."
        )
    }

    /// The localized text copied from the card's context menu for troubleshooting.
    var copyableText: String {
        "\(title)\n\(errorText)\n\(recoveryText)"
    }
}
