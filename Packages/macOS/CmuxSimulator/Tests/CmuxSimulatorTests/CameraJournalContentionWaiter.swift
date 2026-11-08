@testable import CmuxSimulator

struct CameraJournalContentionWaiter: SimulatorMutationLockWaiting {
    let probe: CameraJournalLockRaceProbe
    private let base = ContinuousSimulatorMutationLockWaiter()

    func wait() async throws {
        await probe.publish(.contended)
        try await base.wait()
    }
}
