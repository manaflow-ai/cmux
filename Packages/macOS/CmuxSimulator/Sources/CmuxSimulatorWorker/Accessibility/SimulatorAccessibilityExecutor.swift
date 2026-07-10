import CmuxSimulator
import Foundation

/// Explicitly transfers a private CoreSimulator object into the worker's
/// accessibility actor. The object never leaves the isolated worker process.
struct SimulatorAccessibilityDevice: @unchecked Sendable {
    let object: NSObject

    init(_ object: NSObject) {
        self.object = object
    }
}

protocol SimulatorAccessibilityExecuting: Sendable {
    func attach(device: SimulatorAccessibilityDevice) async -> Bool
    func detach() async
    func foregroundApplication() async throws -> SimulatorApplicationInfo?
    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) async throws -> SimulatorAccessibilitySnapshot
}

/// Owns every private accessibility translator call on one serial executor.
/// Blocking delegate callbacks cannot hold the worker's main actor or race a
/// detach, camera lookup, or accessibility-tree traversal.
actor SimulatorAccessibilityExecutor: SimulatorAccessibilityExecuting {
    private let bridge: SimulatorAccessibilityBridge

    init(bridge: SimulatorAccessibilityBridge = SimulatorAccessibilityBridge()) {
        self.bridge = bridge
    }

    func attach(device: SimulatorAccessibilityDevice) -> Bool {
        bridge.attach(device: device.object)
    }

    func detach() {
        bridge.detach()
    }

    func foregroundApplication() throws -> SimulatorApplicationInfo? {
        try bridge.foregroundApplication()
    }

    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) throws -> SimulatorAccessibilitySnapshot {
        try bridge.accessibilitySnapshot(display: display)
    }
}
