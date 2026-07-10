@testable import CmuxSimulatorUI

struct ImmediateLocationLifecyclePaneSleeper: SimulatorProcessSleeper {
    func sleep(for duration: Duration) async throws {}
}
