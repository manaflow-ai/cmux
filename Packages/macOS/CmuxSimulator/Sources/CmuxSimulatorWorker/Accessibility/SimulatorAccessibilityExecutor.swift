import CmuxSimulator
import Foundation

protocol SimulatorAccessibilityBridging: Sendable {
    func attach(device: NSObject) -> Bool
    func detach()
    func resetAccessibilityConnection()
    func foregroundApplication() throws -> SimulatorApplicationInfo?
    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) throws -> SimulatorAccessibilitySnapshot
}

extension SimulatorAccessibilityBridge: SimulatorAccessibilityBridging {}

/// Owns every private accessibility translator call on one serial executor.
/// Blocking delegate callbacks cannot hold the worker's main actor or race a
/// detach, camera lookup, or accessibility-tree traversal.
actor SimulatorAccessibilityExecutor: SimulatorAccessibilityExecuting {
    private let bridge: any SimulatorAccessibilityBridging
    private let mutationGate: SimulatorMutationGate
    private let retrySleep: @Sendable (Duration) async throws -> Void
    private var attachedDeviceIdentifier: String?
    private static let retryDelays: [Duration] = [
        .zero,
        .milliseconds(100),
        .milliseconds(300),
        .milliseconds(700),
        .milliseconds(1_500),
    ]

    init(
        bridge: any SimulatorAccessibilityBridging = SimulatorAccessibilityBridge(),
        mutationGate: SimulatorMutationGate = SimulatorMutationGate(),
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.bridge = bridge
        self.mutationGate = mutationGate
        self.retrySleep = retrySleep
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

        var lastFailure: SimulatorWorkerFailure?
        for delay in Self.retryDelays {
            try Task.checkCancellation()
            bridge.resetAccessibilityConnection()
            if delay != .zero {
                try await retrySleep(delay)
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
