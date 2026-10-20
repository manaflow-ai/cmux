@testable import CmuxSimulatorWorker

struct ImmediateHIDSleeper: SimulatorHIDSleeping {
    func sleep(for duration: Duration) async throws {}
}
