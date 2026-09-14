import Foundation
import Observation

/// Main-actor state that owns the latest cloud pane creation failure for one workspace.
@MainActor
@Observable
final class CloudPaneCreationFailureStore {
    private(set) var failure: CloudPaneCreationFailure?
    private var activeRequestID: UUID?
    private var retryAction: (() -> Void)?
    var canRetry: Bool { retryAction != nil }

    /// Starts a request and invalidates failures from every older request.
    func beginRequest() -> UUID {
        let requestID = UUID()
        activeRequestID = requestID
        failure = nil
        retryAction = nil
        return requestID
    }

    /// Publishes a newly formatted failure, replacing any older card for this workspace.
    func present(
        machine: SurfaceMachineID,
        error: Error,
        requestID: UUID,
        retry: (() -> Void)? = nil,
        title: String? = nil,
        recoveryText: String? = nil
    ) {
        guard activeRequestID == requestID else { return }
        failure = CloudPaneCreationFailure(
            machine: machine,
            error: error,
            title: title,
            recoveryText: recoveryText
        )
        retryAction = retry
    }

    /// Replays the failed request through its owning action path.
    func retry(id: UUID) {
        guard failure?.id == id, let action = retryAction else { return }
        failure = nil
        retryAction = nil
        activeRequestID = nil
        action()
    }

    /// Removes a card only when the caller is acting on the currently displayed failure.
    func dismiss(id: UUID) {
        guard failure?.id == id else { return }
        failure = nil
        retryAction = nil
        activeRequestID = nil
    }
}
