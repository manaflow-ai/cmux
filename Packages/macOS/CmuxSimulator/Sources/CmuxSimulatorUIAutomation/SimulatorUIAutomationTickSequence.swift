/// A bounded sequence of UI sampling events owned by a scheduler.
public struct SimulatorUIAutomationTickSequence: AsyncSequence, Sendable {
    /// One monotonic event timestamp in milliseconds.
    public typealias Element = Int64
    /// The iterator that emits bounded sampling timestamps.
    public typealias AsyncIterator = SimulatorUIAutomationTickIterator

    private let scheduler: any SimulatorUIAutomationScheduling
    private let intervalMilliseconds: Int64
    private let deadlineMilliseconds: Int64
    private let includesImmediateEvent: Bool

    /// Creates a bounded sequence that ends at the caller's absolute deadline.
    public init(
        scheduler: any SimulatorUIAutomationScheduling,
        intervalMilliseconds: Int64,
        deadlineMilliseconds: Int64,
        includesImmediateEvent: Bool = true
    ) {
        self.scheduler = scheduler
        self.intervalMilliseconds = Swift.max(1, intervalMilliseconds)
        self.deadlineMilliseconds = deadlineMilliseconds
        self.includesImmediateEvent = includesImmediateEvent
    }

    /// Creates an iterator positioned before the first sampling event.
    public func makeAsyncIterator() -> SimulatorUIAutomationTickIterator {
        SimulatorUIAutomationTickIterator(
            scheduler: scheduler,
            intervalMilliseconds: intervalMilliseconds,
            deadlineMilliseconds: deadlineMilliseconds,
            isFirstEvent: true,
            includesImmediateEvent: includesImmediateEvent
        )
    }
}
