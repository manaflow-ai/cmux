import Foundation
import Observation

/// Main-actor state that owns the latest cloud pane creation failure for one workspace.
@MainActor
@Observable
final class CloudPaneCreationFailureStore {
    private var phase: CloudPaneCreationPhase = .idle
    private var activeRequestID: UUID?
    @ObservationIgnored private var failedRequestID: UUID?
    @ObservationIgnored private var requests: [UUID: CloudTerminalCreationCoordinator] = [:]

    var failure: CloudPaneCreationFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }
    var canRetry: Bool { failedRequestID.flatMap { requests[$0] } != nil }
    /// Whether a request is still creating or projecting (tests and diagnostics).
    var hasActiveRequests: Bool { !requests.isEmpty }

    /// Starts a request and invalidates failures from every older request.
    func beginRequest() -> UUID {
        if let failedRequestID { requests.removeValue(forKey: failedRequestID) }
        failedRequestID = nil
        let requestID = UUID()
        activeRequestID = requestID
        phase = .idle
        return requestID
    }

    /// Publishes a newly formatted failure, replacing any older card for this workspace.
    func present(machine: SurfaceMachineID, error: Error, requestID: UUID, title: String? = nil, recoveryText: String? = nil, context: CloudOperationContext? = nil, sourcePanelID: UUID? = nil) {
        guard activeRequestID == requestID else {
            requests.removeValue(forKey: requestID)
            return
        }
        failedRequestID = requestID
        phase = .failed(CloudPaneCreationFailure(machine: machine, error: error, title: title, recoveryText: recoveryText, context: context ?? CloudOperationContext.current, sourcePanelID: sourcePanelID))
    }

    /// Retains each independent intent until it completes or is dismissed. Retry
    /// reuses its creation receipt through the same coordinator. `inlineFailure`
    /// lets a reserved pane show the failure itself; without it the workspace card
    /// is used.
    func run(
        machine: SurfaceMachineID,
        requestID: UUID,
        create: @escaping CloudTerminalCreationCoordinator.Create,
        project: @escaping CloudTerminalCreationCoordinator.Project,
        onStart: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void,
        inlineFailure: (@MainActor (Error) -> Void)? = nil,
        discardProjection: @escaping CloudTerminalCreationCoordinator.DiscardProjection,
        operations: CloudOperationRecorder? = nil
    ) -> CloudTerminalCreationCoordinator {
        let coordinator = CloudTerminalCreationCoordinator(
            create: create,
            project: project,
            onStart: { [weak self] in
                if self?.activeRequestID == requestID {
                    self?.failedRequestID = nil
                    self?.phase = .idle
                }
                onStart()
            },
            onFailure: { [weak self] error in
                onFinish()
                #if DEBUG
                cmuxDebugLog("cloud.pane.createFailed request=\(requestID) machine=\(machine.rawValue) error=\(String(reflecting: error))")
                #endif
                if let inlineFailure {
                    inlineFailure(error)
                } else {
                    self?.present(machine: machine, error: error, requestID: requestID)
                }
            },
            onCancel: { [weak self] in
                onFinish()
                self?.requests.removeValue(forKey: requestID)
                if self?.activeRequestID == requestID { self?.phase = .idle }
            },
            onSuccess: { [weak self] in
                onFinish()
                self?.requests.removeValue(forKey: requestID)
                if self?.activeRequestID == requestID { self?.phase = .idle }
            },
            discardProjection: discardProjection,
            operations: operations
        )
        requests[requestID] = coordinator
        coordinator.start()
        return coordinator
    }

    /// Repeats the current request without minting a second remote creation intent.
    func retry(id: UUID) {
        guard failure?.id == id, let failedRequestID, let coordinator = requests[failedRequestID] else { return }
        coordinator.retry()
    }

    /// Repeats one retained request by id (a reserved pane's Reconnect).
    func retry(requestID: UUID) {
        requests[requestID]?.retry()
    }

    /// Ends one retained request by id (a reserved pane closed by the user).
    func cancel(requestID: UUID) {
        requests.removeValue(forKey: requestID)?.cancel()
        if activeRequestID == requestID { activeRequestID = nil }
        if failedRequestID == requestID {
            failedRequestID = nil
            phase = .idle
        }
    }

    /// Cancels the newest local open request while leaving any remote terminal alive.
    func cancelActiveRequest() {
        guard let activeRequestID else { return }
        requests.removeValue(forKey: activeRequestID)?.cancel()
        self.activeRequestID = nil
        failedRequestID = nil
        phase = .idle
    }

    /// Workspace teardown cancels pending local work without killing remote terminals.
    func cancelAll() {
        let pending = Array(requests.values)
        requests.removeAll()
        phase = .idle
        activeRequestID = nil
        failedRequestID = nil
        for coordinator in pending { coordinator.cancel() }
    }

    /// Removes a card only when the caller is acting on the currently displayed failure.
    func dismiss(id: UUID) {
        guard failure?.id == id else { return }
        if let failedRequestID { requests.removeValue(forKey: failedRequestID)?.cancel() }
        failedRequestID = nil
        phase = .idle
        activeRequestID = nil
    }
}
