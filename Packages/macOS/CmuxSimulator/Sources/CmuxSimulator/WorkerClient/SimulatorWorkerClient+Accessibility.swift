import Foundation

extension SimulatorWorkerClient {
    func performAccessibilityAction(
        _ action: SimulatorControlAction,
        accessibilityTimeout: Duration = .seconds(30),
        accessibilityTimeoutRecovery: SimulatorWorkerRequestTimeoutRecovery = .restartWorker,
        accessibilityRequestIdentifier: UUID? = nil
    ) async throws -> SimulatorControlResult? {
        switch action {
        case .readAccessibility:
            guard currentCapabilities.contains(.accessibility) else {
                throw SimulatorControlError(
                    code: "accessibility_unavailable",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.accessibilityCapability",
                        defaultValue: "The simulator worker does not support accessibility inspection."
                    )
                )
            }
            let requestID = accessibilityRequestIdentifier ?? UUID()
            let response: Result<SimulatorAccessibilitySnapshot, SimulatorFailure> = try await requestWorkerValue(
                sending: .requestAccessibility(requestID),
                timeout: accessibilityTimeout,
                timeoutRecovery: accessibilityTimeoutRecovery
            ) { message in
                switch message {
                case let .accessibility(responseID, snapshot) where responseID == requestID:
                    .success(snapshot)
                case let .requestFailure(responseID, failure) where responseID == requestID:
                    .failure(failure)
                default:
                    nil
                }
            }
            return .accessibility(try response.get())
        case .readForegroundApplication:
            guard currentCapabilities.contains(.foregroundApplication) else {
                throw SimulatorControlError(
                    code: "foreground_application_unavailable",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.foregroundCapability",
                        defaultValue: "The simulator worker does not support foreground-app inspection."
                    )
                )
            }
            let requestID = UUID()
            let response: Result<SimulatorApplicationInfo?, SimulatorFailure> = try await requestWorkerValue(
                sending: .requestForegroundApplication(requestID),
                timeout: .seconds(15),
                timeoutRecovery: .restartWorker
            ) { message in
                switch message {
                case let .foregroundApplication(responseID, application)
                    where responseID == requestID:
                    .some(.success(application))
                case let .requestFailure(responseID, failure) where responseID == requestID:
                    .some(.failure(failure))
                default:
                    nil
                }
            }
            return .foregroundApplication(try response.get())
        default:
            return nil
        }
    }

    /// Reads one bounded accessibility snapshot from the attached Simulator.
    public func readAccessibility(
        timeout: Duration
    ) async throws -> SimulatorControlResult {
        let requestIdentifier = UUID()
        return try await withTaskCancellationHandler {
            do {
                guard let result = try await performAccessibilityAction(
                    .readAccessibility,
                    accessibilityTimeout: timeout,
                    accessibilityTimeoutRecovery: .preserveWorker,
                    accessibilityRequestIdentifier: requestIdentifier
                ) else {
                    throw SimulatorControlError(
                        code: "accessibility_unavailable",
                        arguments: [],
                        message: String(
                            localized: "simulator.failure.accessibilityCapability",
                            defaultValue: "The simulator worker does not support accessibility inspection."
                        )
                    )
                }
                return result
            } catch let error as SimulatorControlError
                where error.code == "worker_response_timed_out" {
                await cancelAccessibilitySnapshotRequest(requestIdentifier)
                throw error
            }
        } onCancel: {
            Task {
                await self.cancelAccessibilitySnapshotRequest(requestIdentifier)
            }
        }
    }

    private func cancelAccessibilitySnapshotRequest(_ requestIdentifier: UUID) async {
        try? await sendRequired(
            .cancelAccessibilitySnapshotRequest(requestIdentifier),
            probe: false
        )
    }
}
