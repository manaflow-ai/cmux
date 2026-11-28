private let simulatorCameraContinuousClock = ContinuousClock()

struct ContinuousSimulatorCameraTiming: SimulatorCameraTiming {
    private let origin: ContinuousClock.Instant

    init() {
        origin = simulatorCameraContinuousClock.now
    }

    func now() -> Duration {
        origin.duration(to: simulatorCameraContinuousClock.now)
    }

    func sleep(for duration: Duration) async throws {
        try await simulatorCameraContinuousClock.sleep(for: duration)
    }

    func sleep(until deadline: Duration, tolerance: Duration) async throws {
        try await simulatorCameraContinuousClock.sleep(
            until: origin.advanced(by: deadline),
            tolerance: tolerance
        )
    }
}
