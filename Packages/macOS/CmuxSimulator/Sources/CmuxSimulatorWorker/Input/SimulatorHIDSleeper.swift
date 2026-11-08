protocol SimulatorHIDSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}
