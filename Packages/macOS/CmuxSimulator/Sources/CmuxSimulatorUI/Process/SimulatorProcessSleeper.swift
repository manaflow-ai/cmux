protocol SimulatorProcessSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}
