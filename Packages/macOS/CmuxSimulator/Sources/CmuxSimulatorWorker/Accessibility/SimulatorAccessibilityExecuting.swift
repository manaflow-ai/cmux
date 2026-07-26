import CmuxSimulator

/// Serial execution boundary for private Simulator accessibility operations.
protocol SimulatorAccessibilityExecuting: Sendable {
    func attach(device: SimulatorAccessibilityDevice) async -> Bool
    func detach() async
    func foregroundApplication() async throws -> SimulatorApplicationInfo?
    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) async throws -> SimulatorAccessibilitySnapshot
}
