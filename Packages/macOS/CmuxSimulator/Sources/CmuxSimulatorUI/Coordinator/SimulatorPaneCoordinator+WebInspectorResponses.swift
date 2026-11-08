import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    static let maximumRetiredWebInspectorRequestIDCount = 128

    /// Sends a raw command and waits for the response carrying the same JSON id.
    public func sendWebInspectorMessageAwaitingResponse(
        _ json: String,
        timeout: Duration = .seconds(15)
    ) async throws -> SimulatorWebInspectorCommandResponse {
        guard let requestID = parseSimulatorWebInspectorJSONRequestID(from: json) else {
            throw SimulatorFailure(
                code: "web_inspector_request_id_required",
                message: String(
                    localized: "simulator.failure.webInspectorRequestIDRequired",
                    defaultValue: "A Web Inspector command must contain a string or numeric id."
                ),
                isRecoverable: true
            )
        }
        guard pendingWebInspectorResponses[requestID] == nil,
              !retiredWebInspectorRequestIDs.contains(requestID) else {
            throw SimulatorFailure(
                code: "web_inspector_request_id_in_use",
                message: String(
                    localized: "simulator.failure.webInspectorRequestIDInUse",
                    defaultValue: "A Web Inspector command with this id is already pending."
                ),
                isRecoverable: true
            )
        }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let sleeper = webInspectorSleeper
                let timeoutTask = Task { @MainActor [weak self] in
                    do {
                        // This bounded sleep is the intended inspector-response deadline.
                        try await sleeper.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.resolveWebInspectorResponse(
                        requestID,
                        retireRequestID: true,
                        with: .failure(SimulatorFailure(
                            code: "web_inspector_response_timeout",
                            message: String(
                                localized: "simulator.failure.webInspectorResponseTimedOut",
                                defaultValue: "The Web Inspector response did not arrive before the bounded deadline."
                            ),
                            isRecoverable: true
                        ))
                    )
                }
                pendingWebInspectorResponses[requestID] = SimulatorPendingWebInspectorResponse(
                    continuation: continuation,
                    timeoutTask: timeoutTask,
                    sendTask: nil
                )
                let sendTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        _ = try await sendWebInspectorMessageResult(json)
                    } catch {
                        resolveWebInspectorResponse(
                            requestID,
                            retireRequestID: true,
                            with: .failure(SimulatorFailure(
                                code: "web_inspector_command_rejected",
                                message: String(describing: error),
                                isRecoverable: true
                            ))
                        )
                    }
                }
                pendingWebInspectorResponses[requestID]?.sendTask = sendTask
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveWebInspectorResponse(
                    requestID,
                    retireRequestID: true,
                    with: .failure(SimulatorFailure(
                        code: "web_inspector_response_cancelled",
                        message: String(
                            localized: "simulator.failure.webInspectorResponseCancelled",
                            defaultValue: "The Web Inspector response wait was cancelled."
                        ),
                        isRecoverable: true
                    ))
                )
            }
        }
        return try result.get()
    }

    func receiveCompletedWebInspectorResponse(_ response: SimulatorWebInspectorResponse) {
        guard let requestID = response.requestID
                ?? parseSimulatorWebInspectorJSONRequestID(from: response.text) else { return }
        if retiredWebInspectorRequestIDs.remove(requestID) != nil { return }
        resolveWebInspectorResponse(
            requestID,
            with: .success(SimulatorWebInspectorCommandResponse(
                text: response.text,
                isTruncated: response.isTruncated
            ))
        )
    }

    func failPendingWebInspectorResponses(
        code: String,
        message: String,
        retireRequestIDs: Bool = true
    ) {
        let requestIDs = Array(pendingWebInspectorResponses.keys)
        for requestID in requestIDs {
            resolveWebInspectorResponse(
                requestID,
                retireRequestID: retireRequestIDs,
                with: .failure(SimulatorFailure(
                    code: code,
                    message: message,
                    isRecoverable: true
                ))
            )
        }
    }

    private func resolveWebInspectorResponse(
        _ requestID: SimulatorWebInspectorJSONRequestID,
        retireRequestID: Bool = false,
        with result: Result<SimulatorWebInspectorCommandResponse, SimulatorFailure>
    ) {
        guard let pending = pendingWebInspectorResponses.removeValue(forKey: requestID) else { return }
        pending.timeoutTask.cancel()
        pending.sendTask?.cancel()
        if retireRequestID { retireWebInspectorRequestID(requestID) }
        pending.continuation.resume(returning: result)
    }

    private func retireWebInspectorRequestID(_ requestID: SimulatorWebInspectorJSONRequestID) {
        guard retiredWebInspectorRequestIDs.count < Self.maximumRetiredWebInspectorRequestIDCount else {
            clearWebInspectorState()
            Task { [client] in await client.invalidateWorker() }
            return
        }
        retiredWebInspectorRequestIDs.insert(requestID)
    }
}
