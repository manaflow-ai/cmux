import Foundation

extension SimulatorWorkerClient {
    func performAccessibilityAction(
        _ action: SimulatorControlAction
    ) async throws -> SimulatorControlResult? {
        switch action {
        case .readAccessibility:
            guard currentCapabilities.contains(.accessibility) else {
                throw SimulatorControlError(
                    code: "accessibility_unavailable",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.accessibilityCapability",
                        defaultValue: "The active Xcode worker did not negotiate accessibility inspection."
                    )
                )
            }
            let requestID = UUID()
            let response: Result<SimulatorAccessibilitySnapshot, SimulatorFailure> = try await requestWorkerValue(
                sending: .requestAccessibility(requestID),
                timeout: .seconds(30),
                timeoutRecovery: .restartWorker
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
                        defaultValue: "The active Xcode worker did not negotiate foreground-app inspection."
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
}
