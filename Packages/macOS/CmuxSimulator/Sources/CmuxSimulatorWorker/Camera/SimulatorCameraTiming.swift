protocol SimulatorCameraTiming: Sendable {
    func now() -> Duration
    func sleep(for duration: Duration) async throws
    func sleep(until deadline: Duration, tolerance: Duration) async throws
}
