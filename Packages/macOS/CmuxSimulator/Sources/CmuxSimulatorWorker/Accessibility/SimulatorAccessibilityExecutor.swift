import CmuxSimulator
import Foundation

/// Owns every private accessibility translator call on one serial executor.
/// Blocking delegate callbacks cannot hold the worker's main actor or race a
/// detach, camera lookup, or accessibility-tree traversal.
actor SimulatorAccessibilityExecutor: SimulatorAccessibilityExecuting {
    private let bridge: any SimulatorAccessibilityBridging
    private let mutationGate: SimulatorMutationGate
    private let retrySchedule: SimulatorAccessibilityRetrySchedule
    private var attachedDeviceIdentifier: String?

    init(
        bridge: any SimulatorAccessibilityBridging = SimulatorAccessibilityBridge(),
        mutationGate: SimulatorMutationGate = SimulatorMutationGate(),
        retrySchedule: SimulatorAccessibilityRetrySchedule =
            SimulatorAccessibilityRetrySchedule()
    ) {
        self.bridge = bridge
        self.mutationGate = mutationGate
        self.retrySchedule = retrySchedule
    }

    func attach(
        device: SimulatorAccessibilityDevice,
        deviceIdentifier: String
    ) async -> Bool {
        bridge.detach()
        attachedDeviceIdentifier = nil
        guard bridge.attach(device: device.object) else { return false }
        attachedDeviceIdentifier = deviceIdentifier
        return true
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
        let lease = try await mutationGate.acquireLocks([
            .accessibility(deviceIdentifier: attachedDeviceIdentifier),
        ], isolation: self)
        defer { lease.release() }

        // A process-local actor cannot serialize sibling cmux worker processes.
        // The keyed lease is the smallest crash-safe boundary around the
        // CoreSimulator connection retained per device.
        var lastFailure: SimulatorWorkerFailure?
        for try await _ in retrySchedule {
            bridge.resetAccessibilityConnection()
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
