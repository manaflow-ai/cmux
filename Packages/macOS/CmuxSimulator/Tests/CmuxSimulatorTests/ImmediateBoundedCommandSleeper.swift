import Foundation
@testable import CmuxSimulator

struct ImmediateBoundedCommandSleeper: SimulatorWorkerSleeping {
    func sleep(for duration: Duration) async throws {}
}
