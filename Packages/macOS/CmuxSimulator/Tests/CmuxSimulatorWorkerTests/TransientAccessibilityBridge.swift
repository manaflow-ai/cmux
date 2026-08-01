import CmuxSimulator
import Foundation
@testable import CmuxSimulatorWorker

// The retry executor calls this fixture serially, so its counter has one owner.
final class TransientAccessibilityBridge:
    SimulatorAccessibilityBridging,
    @unchecked Sendable
{
    private let failuresBeforeSuccess: Int
    private(set) var foregroundCallCount = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func attach(device _: NSObject) -> Bool { true }
    func detach() {}
    func resetAccessibilityConnection() {}
    func probeAccessibility() throws {}

    func foregroundApplication() throws -> SimulatorApplicationInfo? {
        foregroundCallCount += 1
        if foregroundCallCount <= failuresBeforeSuccess {
            throw SimulatorWorkerFailure.accessibilityUnavailable(
                "The application accessibility root is still starting."
            )
        }
        return SimulatorApplicationInfo(
            bundleIdentifier: "com.example.ready",
            processIdentifier: 123,
            name: "Ready",
            version: nil,
            build: nil,
            minimumOSVersion: nil,
            isReactNative: false
        )
    }

    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) throws -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(roots: [], display: display)
    }
}
