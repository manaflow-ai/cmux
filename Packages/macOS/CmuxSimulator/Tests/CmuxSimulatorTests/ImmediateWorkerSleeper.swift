import Foundation
@testable import CmuxSimulator

struct ImmediateWorkerSleeper: SimulatorWorkerSleeping {
    func sleep(for duration: Duration) async throws {}
}
