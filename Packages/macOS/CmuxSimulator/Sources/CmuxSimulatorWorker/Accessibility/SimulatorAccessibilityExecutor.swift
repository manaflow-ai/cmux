import CmuxSimulator
import Foundation

/// Owns every private accessibility translator call on one serial executor.
/// Blocking delegate callbacks cannot hold the worker's main actor or race a
/// detach, camera lookup, or accessibility-tree traversal.
actor SimulatorAccessibilityExecutor: SimulatorAccessibilityExecuting {
    private let bridge: SimulatorAccessibilityBridge
    private let mutationGate: SimulatorMutationGate
    private var attachedDeviceIdentifier: String?
    private static let retryDelays: [Duration] = [
        .zero,
        .milliseconds(100),
        .milliseconds(300),
    ]

    init(
        bridge: SimulatorAccessibilityBridge = SimulatorAccessibilityBridge(),
        mutationGate: SimulatorMutationGate = SimulatorMutationGate()
    ) {
        self.bridge = bridge
        self.mutationGate = mutationGate
    }

    func attach(
        device: SimulatorAccessibilityDevice,
        deviceIdentifier: String
    ) async -> Bool {
        bridge.detach()
        attachedDeviceIdentifier = nil
        guard bridge.attach(device: device.object) else { return false }
        attachedDeviceIdentifier = deviceIdentifier
        do {
            try await performWithExclusiveConnection {
                try bridge.probeAccessibility()
            }
            return true
        } catch {
            bridge.detach()
            attachedDeviceIdentifier = nil
            return false
        }
    }

    func detach() {
        bridge.detach()
        attachedDeviceIdentifier = nil
    }

    func foregroundApplication() async throws -> SimulatorApplicationInfo? {
        try await performWithExclusiveConnection {
            try bridge.foregroundApplication()
        }
    }

    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) async throws -> SimulatorAccessibilitySnapshot {
        try await performWithExclusiveConnection {
            try bridge.accessibilitySnapshot(display: display)
        }
    }

    private func performWithExclusiveConnection<Result>(
        _ operation: () throws -> Result
    ) async throws -> Result {
        guard let attachedDeviceIdentifier else {
            throw SimulatorWorkerFailure.accessibilityUnavailable(
                "No Simulator is attached."
            )
        }
        return try await mutationGate.withLocks([
            .accessibility(deviceIdentifier: attachedDeviceIdentifier),
        ]) {
            var lastFailure: SimulatorWorkerFailure?
            for delay in Self.retryDelays {
                try Task.checkCancellation()
                bridge.resetAccessibilityConnection()
                if delay != .zero {
                    try await ContinuousClock().sleep(for: delay)
                }
                do {
                    let result = try operation()
                    bridge.resetAccessibilityConnection()
                    return result
                } catch let failure as SimulatorWorkerFailure {
                    bridge.resetAccessibilityConnection()
                    guard case .accessibilityUnavailable = failure else {
                        throw failure
                    }
                    lastFailure = failure
                } catch {
                    bridge.resetAccessibilityConnection()
                    throw error
                }
            }
            throw lastFailure ?? SimulatorWorkerFailure.accessibilityUnavailable(
                "The Simulator accessibility connection could not be established."
            )
        }
    }
}
