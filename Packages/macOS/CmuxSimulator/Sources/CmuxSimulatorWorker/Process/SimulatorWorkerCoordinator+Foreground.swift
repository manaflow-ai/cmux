import CmuxSimulator
import Foundation

extension SimulatorWorkerCoordinator {
    func requestForegroundApplication(requestIdentifier: UUID) {
        if foregroundApplicationTask != nil,
           foregroundApplicationGeneration == nil {
            send(.requestFailure(
                requestID: requestIdentifier,
                SimulatorFailure(
                    code: "foreground_request_busy",
                    message: String(
                        localized: "simulator.failure.foregroundRequestUnwinding",
                        defaultValue: "The previous foreground-application read is still unwinding."
                    ),
                    isRecoverable: true
                )
            ))
            return
        }
        guard foregroundApplicationRequestIdentifiers.count <
            SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount
        else {
            send(.requestFailure(
                requestID: requestIdentifier,
                SimulatorFailure(
                    code: "foreground_request_busy",
                    message: String(
                        localized: "simulator.failure.foregroundRequestBusy",
                        defaultValue: "A foreground-application read is already at capacity."
                    ),
                    isRecoverable: true
                )
            ))
            return
        }
        foregroundApplicationRequestIdentifiers.append(requestIdentifier)
        guard foregroundApplicationTask == nil else { return }

        let deviceIdentifier = currentDeviceIdentifier
        let executor = accessibilityExecutor
        let generation = UUID()
        foregroundApplicationGeneration = generation
        foregroundApplicationTask = Task { @MainActor [weak self] in
            let result: Result<SimulatorApplicationInfo?, any Error>
            do {
                result = .success(try await executor.foregroundApplication())
            } catch {
                result = .failure(error)
            }

            guard let self else { return }
            guard self.foregroundApplicationGeneration == generation else {
                self.foregroundApplicationTask = nil
                return
            }
            let requestIdentifiers = self.foregroundApplicationRequestIdentifiers
            self.foregroundApplicationRequestIdentifiers.removeAll()
            self.foregroundApplicationGeneration = nil
            self.foregroundApplicationTask = nil
            guard !Task.isCancelled,
                  self.currentDeviceIdentifier == deviceIdentifier
            else { return }

            switch result {
            case let .success(application):
                for requestIdentifier in requestIdentifiers {
                    self.send(.foregroundApplication(
                        requestID: requestIdentifier,
                        application
                    ))
                }
            case let .failure(error):
                for requestIdentifier in requestIdentifiers {
                    self.report(error, requestID: requestIdentifier)
                }
            }
        }
    }

    func cancelForegroundApplicationRequests() {
        for requestIdentifier in foregroundApplicationRequestIdentifiers {
            send(.requestFailure(
                requestID: requestIdentifier,
                SimulatorFailure(
                    code: "foreground_request_cancelled",
                    message: String(
                        localized: "simulator.failure.foregroundRequestCancelled",
                        defaultValue: "The Simulator changed during foreground-app inspection."
                    ),
                    isRecoverable: true
                )
            ))
        }
        foregroundApplicationTask?.cancel()
        foregroundApplicationGeneration = nil
        foregroundApplicationRequestIdentifiers.removeAll()
    }
}
