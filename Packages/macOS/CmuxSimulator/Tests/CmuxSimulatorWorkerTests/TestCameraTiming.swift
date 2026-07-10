@testable import CmuxSimulatorWorker

struct TestCameraTiming: SimulatorCameraTiming {
    let probe: CameraTimingProbe

    func now() -> Duration { .zero }

    func sleep(for duration: Duration) async throws {
        try await probe.sleep()
    }

    func sleep(until deadline: Duration, tolerance: Duration) async throws {
        try await probe.sleep()
    }
}
