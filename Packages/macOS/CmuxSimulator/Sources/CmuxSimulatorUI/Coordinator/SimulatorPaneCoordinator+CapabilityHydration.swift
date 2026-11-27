import CmuxSimulator
import Foundation

extension SimulatorPaneCoordinator {
    /// Waits for optional attachment probes without delaying core framebuffer readiness.
    public func waitForCapabilityHydration() async throws {
        if capabilityHydrationCompleted { return }
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
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if capabilityHydrationCompleted {
                    continuation.resume()
                } else if status != .streaming {
                    continuation.resume()
                } else {
                    capabilityHydrationWaiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveCapabilityHydrationWaiter(waiterID)
            }
        }

        try Task.checkCancellation()
        guard capabilityHydrationCompleted else {
            throw failure ?? SimulatorFailure(
                code: "simulator_capability_hydration_interrupted",
                message: String(
                    localized: "simulator.failure.rendererStopped",
                    defaultValue: "The Simulator renderer stopped"
                ),
                isRecoverable: true
            )
        }
    }

    func resetCapabilityHydration() {
        capabilityHydrationCompleted = false
        resolveCapabilityHydrationWaiters()
    }

    func resolveCapabilityHydrationWaiters() {
        let waiters = capabilityHydrationWaiters.values
        capabilityHydrationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func resolveCapabilityHydrationWaiter(_ waiterID: UUID) {
        capabilityHydrationWaiters.removeValue(forKey: waiterID)?.resume()
    }
}
