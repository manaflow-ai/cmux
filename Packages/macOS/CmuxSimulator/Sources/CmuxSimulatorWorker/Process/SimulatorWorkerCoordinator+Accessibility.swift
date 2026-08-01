import CmuxSimulator
import Foundation

extension SimulatorWorkerCoordinator {
    private static let accessibilitySnapshotHardDeadline: Duration = .seconds(30)

    func requestAccessibility(requestIdentifier: UUID) {
        guard let display = currentDisplay else {
            send(
                .requestFailure(
                    requestID: requestIdentifier,
                    SimulatorFailure(
                        code: "accessibility_unavailable",
                        message: String(
                            localized: "simulator.failure.accessibilityFramebufferRequired",
                            defaultValue: "Accessibility requires a live framebuffer."
                        ),
                        isRecoverable: true
                    )
                ))
            return
        }
        guard
            accessibilitySnapshotRequestIdentifiers.count
                < SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount,
            accessibilitySnapshotTask == nil
                || (accessibilitySnapshotGeneration != nil
                    && accessibilitySnapshotDeviceIdentifier == currentDeviceIdentifier
                    && accessibilitySnapshotDisplay == display)
        else {
            send(
                .requestFailure(
                    requestID: requestIdentifier,
                    SimulatorFailure(
                        code: "accessibility_request_busy",
                        message: String(
                            localized: "simulator.failure.accessibilityRequestBusy",
                            defaultValue: "An accessibility snapshot is already at capacity."
                        ),
                        isRecoverable: true
                    )
                ))
            return
        }
        accessibilitySnapshotRequestIdentifiers.append(requestIdentifier)
        guard accessibilitySnapshotTask == nil else { return }

        let deviceIdentifier = currentDeviceIdentifier
        let executor = accessibilityExecutor
        let generation = UUID()
        accessibilitySnapshotGeneration = generation
        accessibilitySnapshotDeviceIdentifier = deviceIdentifier
        accessibilitySnapshotDisplay = display
        accessibilitySnapshotTask = Task { @MainActor [weak self] in
            let result: Result<SimulatorAccessibilitySnapshot, any Error>
            do {
                result = .success(try await executor.accessibilitySnapshot(display: display))
            } catch {
                result = .failure(error)
            }

            guard let self else { return }
            guard self.accessibilitySnapshotGeneration == generation else {
                return
            }
            let requestIdentifiers = self.accessibilitySnapshotRequestIdentifiers
            self.clearAccessibilitySnapshotRequestState(clearCache: false)
            guard !Task.isCancelled,
                self.currentDeviceIdentifier == deviceIdentifier,
                self.currentDisplay == display
            else { return }

            switch result {
            case .success(let snapshot):
                self.cachedAccessibilitySnapshot = snapshot
                for requestIdentifier in requestIdentifiers {
                    self.send(.accessibility(requestID: requestIdentifier, snapshot))
                }
            case .failure(let error):
                for requestIdentifier in requestIdentifiers {
                    self.report(error, requestID: requestIdentifier)
                }
            }
        }
        startAccessibilitySnapshotDeadline(generation: generation)
    }

    func cancelAccessibilitySnapshotRequests() {
        for requestIdentifier in accessibilitySnapshotRequestIdentifiers {
            send(
                .requestFailure(
                    requestID: requestIdentifier,
                    SimulatorFailure(
                        code: "accessibility_snapshot_stale",
                        message: String(
                            localized: "simulator.failure.accessibilitySnapshotStale",
                            defaultValue: "The Simulator display changed during accessibility inspection."
                        ),
                        isRecoverable: true
                    )
                ))
        }
        accessibilitySnapshotTask?.cancel()
        clearAccessibilitySnapshotRequestState(clearCache: true)
    }

    private func clearAccessibilitySnapshotRequestState(clearCache: Bool) {
        accessibilitySnapshotDeadlineTask?.cancel()
        accessibilitySnapshotDeadlineTask = nil
        accessibilitySnapshotCancellationGraceTask?.cancel()
        accessibilitySnapshotCancellationGraceTask = nil
        accessibilitySnapshotTask = nil
        accessibilitySnapshotGeneration = nil
        accessibilitySnapshotRequestIdentifiers.removeAll()
        accessibilitySnapshotDeviceIdentifier = nil
        accessibilitySnapshotDisplay = nil
        if clearCache { cachedAccessibilitySnapshot = nil }
    }

    private func startAccessibilitySnapshotDeadline(generation: UUID) {
        let sleeper = toolOperationSleeper
        accessibilitySnapshotDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await sleeper.sleep(for: Self.accessibilitySnapshotHardDeadline)
            } catch {
                return
            }
            guard !Task.isCancelled, let self,
                  self.accessibilitySnapshotGeneration == generation,
                  self.accessibilitySnapshotTask != nil else { return }
            self.accessibilitySnapshotTask?.cancel()
            let containment = self.toolOperationContainment
            self.accessibilitySnapshotCancellationGraceTask = Task {
                do {
                    try await sleeper.sleep(for: containment.cancellationGrace)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.accessibilitySnapshotGeneration == generation,
                      self.accessibilitySnapshotTask != nil else { return }
                containment.terminate()
            }
        }
    }
}
