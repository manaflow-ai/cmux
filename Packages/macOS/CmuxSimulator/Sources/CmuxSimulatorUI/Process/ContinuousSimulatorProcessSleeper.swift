struct ContinuousSimulatorProcessSleeper: SimulatorProcessSleeper {
    private let clock = ContinuousClock()

    func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}
