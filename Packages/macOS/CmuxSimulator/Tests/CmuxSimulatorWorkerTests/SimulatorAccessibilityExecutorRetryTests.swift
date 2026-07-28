import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator accessibility retries")
struct SimulatorAccessibilityExecutorRetryTests {
    @Test("A foreground lookup survives four transient connection failures")
    func foregroundRetriesAcrossApplicationStartup() async throws {
        let bridge = TransientAccessibilityBridge(failuresBeforeSuccess: 4)
        let executor = SimulatorAccessibilityExecutor(
            bridge: bridge,
            retrySleep: { _ in }
        )

        #expect(await executor.attach(
            device: SimulatorAccessibilityDevice(NSObject()),
            deviceIdentifier: "DEVICE"
        ))
        let application = try await executor.foregroundApplication()

        #expect(application?.bundleIdentifier == "com.example.ready")
        #expect(bridge.foregroundCallCount == 5)
    }
}

private final class TransientAccessibilityBridge:
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
