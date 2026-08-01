/// Iterates cancellation-aware sampling times up to one monotonic deadline.
public struct SimulatorUIAutomationTickIterator: AsyncIteratorProtocol {
    private let scheduler: any SimulatorUIAutomationScheduling
    private let intervalMilliseconds: Int64
    private let deadlineMilliseconds: Int64
    private var isFirstEvent: Bool
    private let includesImmediateEvent: Bool

    init(
        scheduler: any SimulatorUIAutomationScheduling,
        intervalMilliseconds: Int64,
        deadlineMilliseconds: Int64,
        isFirstEvent: Bool,
        includesImmediateEvent: Bool
    ) {
        self.scheduler = scheduler
        self.intervalMilliseconds = intervalMilliseconds
        self.deadlineMilliseconds = deadlineMilliseconds
        self.isFirstEvent = isFirstEvent
        self.includesImmediateEvent = includesImmediateEvent
    }

    /// Returns the next monotonic event timestamp, or `nil` at the deadline.
    public mutating func next() async throws -> Int64? {
        try Task.checkCancellation()
        let beforeWait = scheduler.monotonicNowMilliseconds()
        if isFirstEvent, includesImmediateEvent {
            isFirstEvent = false
            return beforeWait
        }
        isFirstEvent = false
        guard beforeWait < deadlineMilliseconds else { return nil }
        try await scheduler.nextEvent(after: .milliseconds(Swift.min(
            intervalMilliseconds,
            deadlineMilliseconds - beforeWait
        )))
        let afterWait = scheduler.monotonicNowMilliseconds()
        guard afterWait < deadlineMilliseconds else { return nil }
        return afterWait
    }
}
