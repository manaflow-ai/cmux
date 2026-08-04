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
            retrySchedule: SimulatorAccessibilityRetrySchedule(
                nextEvent: { _ in }
            )
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
