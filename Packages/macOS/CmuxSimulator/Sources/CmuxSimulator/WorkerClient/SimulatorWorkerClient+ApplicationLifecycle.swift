import Foundation

extension SimulatorWorkerClient {
    func performApplicationLifecycleAction(
        _ action: SimulatorControlAction
    ) async throws -> SimulatorControlResult? {
        guard case let .terminateApplication(deviceIdentifier, bundleIdentifier) = action
        else { return nil }
        if child != nil,
           simulatorAttachedDeviceIdentifier(from: lastAttachment) == deviceIdentifier {
            let requestIdentifier = UUID()
            let succeeded: Bool = try await requestWorkerValue(
                sending: .prepareApplicationMutation(
                    requestID: requestIdentifier,
                    bundleIdentifier: bundleIdentifier
                ),
                timeout: .seconds(30),
                timeoutRecovery: .restartWorker
            ) { message in
                guard case let .applicationMutationPrepared(responseID, succeeded) = message,
                      responseID == requestIdentifier else { return nil }
                return succeeded
            }
            guard succeeded else {
                throw SimulatorControlError(
                    code: "application_mutation_preparation_failed",
                    arguments: [],
                    message: String(
                        localized: "simulator.failure.applicationMutationPreparation",
                        defaultValue: "The Simulator worker could not release camera and inspector ownership of the app."
                    )
                )
            }
        }
        let result = try await simulatorControl.perform(action)
        retireCameraTarget(bundleIdentifier)
        return result
    }

    func retireCameraTarget(_ bundleIdentifier: String) {
        cameraReplayConfigurations.removeAll {
            $0.targetBundleIdentifier == bundleIdentifier
        }
        cameraCleanupBundleIdentifiers.remove(bundleIdentifier)
        cameraCleanupOwners.removeValue(forKey: bundleIdentifier)
        cameraRequestConfigurations = cameraRequestConfigurations.filter {
            $0.value.targetBundleIdentifier != bundleIdentifier
        }
        if cameraReplayConfigurations.isEmpty { lastCameraMirrorMode = nil }
    }
}
