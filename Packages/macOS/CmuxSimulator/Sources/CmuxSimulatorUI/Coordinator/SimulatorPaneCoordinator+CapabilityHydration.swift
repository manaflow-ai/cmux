import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Waits only for the optional capability required by one operation.
    public func waitForCapabilityResolution(
        _ capability: SimulatorCapability,
        timeout: Duration = .seconds(15)
    ) async throws {
        if capabilityResolutions[capability] != nil { return }
        guard status == .streaming else {
            throw SimulatorFailure(
                code: "simulator_not_streaming",
                message: String(
                    localized: "simulator.failure.rendererStopped",
                    defaultValue: "The Simulator renderer stopped"
                ),
                isRecoverable: true
            )
        }

        let waiterID = UUID()
        let sleeper = capabilityResolutionSleeper
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if let _ = capabilityResolutions[capability] {
                    continuation.resume()
                    return
                }
                guard status == .streaming else {
                    continuation.resume(throwing: capabilityResolutionInterruptedFailure())
                    return
                }
                capabilityResolutionWaiters[capability, default: [:]][waiterID] =
                    continuation
                capabilityResolutionTimeoutTasks[waiterID] = Task { @MainActor [weak self] in
                    do {
                        try await sleeper.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    self?.timeoutCapabilityResolutionWaiter(
                        waiterID,
                        capability: capability
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCapabilityResolutionWaiter(
                    waiterID,
                    capability: capability
                )
            }
        }
        try Task.checkCancellation()
    }

    func applyCapabilityResolution(
        _ capability: SimulatorCapability,
        available: Bool
    ) {
        capabilityResolutions[capability] = available
        if available {
            capabilities.insert(capability)
        } else {
            capabilities.remove(capability)
        }
        let waiters = capabilityResolutionWaiters.removeValue(
            forKey: capability
        ) ?? [:]
        for (waiterID, continuation) in waiters {
            capabilityResolutionTimeoutTasks.removeValue(forKey: waiterID)?.cancel()
            continuation.resume()
        }
    }

    func resetCapabilityHydration() {
        capabilityResolutions = [:]
        let failure = capabilityResolutionInterruptedFailure()
        let waiters = capabilityResolutionWaiters.values.flatMap(\.values)
        capabilityResolutionWaiters = [:]
        for task in capabilityResolutionTimeoutTasks.values {
            task.cancel()
        }
        capabilityResolutionTimeoutTasks = [:]
        for continuation in waiters {
            continuation.resume(throwing: failure)
        }
    }

    private func timeoutCapabilityResolutionWaiter(
        _ waiterID: UUID,
        capability: SimulatorCapability
    ) {
        guard let continuation = removeCapabilityResolutionWaiter(
            waiterID,
            capability: capability
        ) else { return }
        continuation.resume(throwing: SimulatorFailure(
            code: "simulator_capability_resolution_timed_out",
            message: String(
                localized: "simulator.failure.workerResponseTimedOut",
                defaultValue: "The Simulator worker did not reply before the bounded deadline."
            ),
            isRecoverable: true
        ))
    }

    private func cancelCapabilityResolutionWaiter(
        _ waiterID: UUID,
        capability: SimulatorCapability
    ) {
        guard let continuation = removeCapabilityResolutionWaiter(
            waiterID,
            capability: capability
        ) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func removeCapabilityResolutionWaiter(
        _ waiterID: UUID,
        capability: SimulatorCapability
    ) -> CheckedContinuation<Void, any Error>? {
        capabilityResolutionTimeoutTasks.removeValue(forKey: waiterID)?.cancel()
        let continuation = capabilityResolutionWaiters[capability]?.removeValue(
            forKey: waiterID
        )
        if capabilityResolutionWaiters[capability]?.isEmpty == true {
            capabilityResolutionWaiters.removeValue(forKey: capability)
        }
        return continuation
    }

    private func capabilityResolutionInterruptedFailure() -> SimulatorFailure {
        failure ?? SimulatorFailure(
            code: "simulator_capability_resolution_interrupted",
            message: String(
                localized: "simulator.failure.rendererStopped",
                defaultValue: "The Simulator renderer stopped"
            ),
            isRecoverable: true
        )
    }
}
