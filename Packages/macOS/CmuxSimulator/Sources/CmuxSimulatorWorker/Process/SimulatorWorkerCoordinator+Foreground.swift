import CmuxSimulator
import Foundation

extension SimulatorWorkerCoordinator {
    func requestForegroundApplication(requestIdentifier: UUID) {
        guard foregroundApplicationRequestIdentifiers.count <
            SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount
        else {
            send(.requestFailure(
                requestID: requestIdentifier,
                SimulatorFailure(
                    code: "foreground_request_busy",
                    message: "A foreground-application read is already at capacity.",
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

            guard let self,
                  self.foregroundApplicationGeneration == generation
            else { return }
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
        foregroundApplicationTask?.cancel()
        foregroundApplicationTask = nil
        foregroundApplicationGeneration = nil
        foregroundApplicationRequestIdentifiers.removeAll()
    }
}
