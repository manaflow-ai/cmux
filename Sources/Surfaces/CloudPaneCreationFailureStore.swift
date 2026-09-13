import Foundation
import Observation

/// Main-actor state that owns the latest cloud pane creation failure for one workspace.
@MainActor
@Observable
final class CloudPaneCreationFailureStore {
    private(set) var failure: CloudPaneCreationFailure?

    /// Publishes a newly formatted failure, replacing any older card for this workspace.
    func present(machine: SurfaceMachineID, error: Error) {
        failure = CloudPaneCreationFailure(machine: machine, error: error)
    }

    /// Removes a card only when the caller is acting on the currently displayed failure.
    func dismiss(id: UUID) {
        guard failure?.id == id else { return }
        failure = nil
    }

    /// Clears a previous failure before a new creation request begins.
    func clear() {
        failure = nil
    }
}
