import Foundation
import Observation

/// Main-actor state that owns the latest cloud pane creation failure for one workspace.
@MainActor
@Observable
final class CloudPaneCreationFailureStore {
    private(set) var failure: CloudPaneCreationFailure?
    private var activeRequestID: UUID?

    /// Starts a request and invalidates failures from every older request.
    func beginRequest() -> UUID {
        let requestID = UUID()
        activeRequestID = requestID
        failure = nil
        return requestID
    }

    /// Publishes a newly formatted failure, replacing any older card for this workspace.
    func present(machine: SurfaceMachineID, error: Error, requestID: UUID) {
        guard activeRequestID == requestID else { return }
        failure = CloudPaneCreationFailure(machine: machine, error: error)
    }

    /// Removes a card only when the caller is acting on the currently displayed failure.
    func dismiss(id: UUID) {
        guard failure?.id == id else { return }
        failure = nil
        activeRequestID = nil
    }
}
