protocol SimulatorHIDSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousSimulatorHIDSleeper: SimulatorHIDSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}
