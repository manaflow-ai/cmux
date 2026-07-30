/// Schedules cancellation-aware sampling without coupling automation to a clock.
public protocol SimulatorUIAutomationScheduling: Sendable {
    /// Returns Unix epoch time in milliseconds.
    func nowMilliseconds() -> Int64
    /// Produces the next scheduled event or throws when cancellation wins.
    func nextEvent(after duration: Duration) async throws
}

/// A bounded sequence of UI sampling events owned by a scheduler.
public struct SimulatorUIAutomationTickSequence: AsyncSequence, Sendable {
    public typealias Element = Int64

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

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            scheduler: scheduler,
            intervalMilliseconds: intervalMilliseconds,
            deadlineMilliseconds: deadlineMilliseconds,
            isFirstEvent: true,
            includesImmediateEvent: includesImmediateEvent
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let scheduler: any SimulatorUIAutomationScheduling
        private let intervalMilliseconds: Int64
        private let deadlineMilliseconds: Int64
        private var isFirstEvent: Bool
        private let includesImmediateEvent: Bool

        fileprivate init(
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

        public mutating func next() async throws -> Int64? {
            try Task.checkCancellation()
            let beforeWait = scheduler.nowMilliseconds()
            if isFirstEvent, includesImmediateEvent {
                isFirstEvent = false
                guard beforeWait <= deadlineMilliseconds else { return nil }
                return beforeWait
            }
            isFirstEvent = false
            guard beforeWait < deadlineMilliseconds else { return nil }
            try await scheduler.nextEvent(after: .milliseconds(Swift.min(
                intervalMilliseconds,
                deadlineMilliseconds - beforeWait
            )))
            let afterWait = scheduler.nowMilliseconds()
            guard afterWait < deadlineMilliseconds else { return nil }
            return afterWait
        }
    }
}
