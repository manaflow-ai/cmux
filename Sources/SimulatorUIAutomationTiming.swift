/// Supplies cancellable delays and time to Simulator UI automation.
protocol SimulatorUIAutomationTiming: Sendable {
    func nowMilliseconds() -> Int64
    func sleep(for duration: Duration) async throws
}
