import Foundation

/// What the person is told when a background create needs an actionable
/// notification. Successful creates are represented by their bound workspace
/// and Cloud tree row, so this value exists only for failures.
struct MachineCreateNotice: Equatable {
    let title: String
    let subtitle: String
    let body: String
    /// The local workspace the machine opened into, when the CLI reported one.
    let workspaceID: UUID?
    /// True for the two failure outcomes; the notifier keys cooldowns and the
    /// panel's inline error off this.
    let isFailure: Bool

    init?(finished: MachineCreateCoordinator.Finished) {
        let request = finished.operation.request
        let subtitle = request.isBaseSetup
            ? String(localized: "machines.new.title.base", defaultValue: "Set Up Base")
            : String(localized: "machines.new.title", defaultValue: "New Machine")
        switch finished.outcome {
        case .created:
            return nil
        case .createdButOpenFailed(let machineID, let output):
            title = String(
                format: String(
                    localized: "machines.notification.createdOpenFailed.title",
                    defaultValue: "%@ was created, but opening it failed"
                ),
                machineID
            )
            self.subtitle = subtitle
            body = Self.body(
                lead: String(localized: "machines.notification.createdOpenFailed.body", defaultValue: "Open it from the Machines list."),
                output: output
            )
            workspaceID = nil
            isFailure = true
        case .failed(let output):
            title = request.failureLabel
            self.subtitle = request.displayName
            body = Self.body(
                lead: String(localized: "machines.notification.failed.body", defaultValue: "Retry or dismiss it from the Machines list."),
                output: output
            )
            workspaceID = request.baseWorkspaceID
            isFailure = true
        }
    }

    private static func body(lead: String, output: String) -> String {
        guard let reason = MachineCreateOperation.headline(ofOutput: output) else { return lead }
        return "\(reason)\n\(lead)"
    }
}
