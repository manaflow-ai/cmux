import Foundation
@testable import CmuxSimulator

actor CancellableWorkerSleeper: SimulatorWorkerSleeping {
    private var started = false
    private var cancelled = false

    var hasStarted: Bool { started }
    var wasCancelled: Bool { cancelled }

    func sleep(for duration: Duration) async throws {
        started = true
        do {
            try await ContinuousClock().sleep(for: .seconds(3_600))
        } catch {
            cancelled = true
            throw error
        }
    }
}
