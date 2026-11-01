import CmuxNextTestSupport
import Testing

/// The shared fixtures' limiter (TestPermits): the bound, first come first served, cancellation
/// and nesting. Each test uses its own limiter, so the shared one's state never matters here.
@Suite(.timeLimit(.minutes(1)))
struct TestPermitsTests {
    /// Yields until `condition` holds, up to five seconds; records an issue if it never does.
    private static func until(_ what: String, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "never: \(what)", sourceLocation: sourceLocation)
    }

    /// Permits in use and callers waiting.
    private static func usage(_ permits: TestPermits) -> [Int] { [permits.usage.inUse, permits.usage.waiting] }

    /// What a waiter's task saw, read back on the main actor after it ran.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
        nonisolated deinit {}
    }

    @Test func noMoreThanTheLimitHoldAPermitAndAReleaseLetsTheNextIn() async throws {
        let permits = TestPermits(limit: 2)
        try await permits.acquire()
        try await permits.acquire()
        #expect(Self.usage(permits) == [2, 0])

        let thirdGotIn = Box(false)
        let third = Task {
            try await permits.acquire()
            thirdGotIn.value = true
        }
        try await Self.until("the third caller waits") { permits.usage.waiting == 1 }
        #expect(!thirdGotIn.value, "a third caller got a permit while two were held")

        permits.release()
        try await third.value
        #expect(thirdGotIn.value)
        #expect(Self.usage(permits) == [2, 0])
        permits.release()
        permits.release()
        #expect(Self.usage(permits) == [0, 0])
    }

    @Test func waitersGetTheirPermitsInTheOrderTheyAsked() async throws {
        let permits = TestPermits(limit: 1)
        try await permits.acquire()
        let order = Box<[Int]>([])
        var waiters: [Task<Void, any Error>] = []
        for index in 1...6 {
            waiters.append(Task {
                try await permits.withPermit { order.value.append(index) }
            })
            // Each one queues before the next asks, so "asked first" is well defined.
            try await Self.until("waiter \(index) queues") { permits.usage.waiting == index }
        }
        // A caller that comes now must not go ahead of the six that wait.
        let late = Task { try await permits.withPermit { order.value.append(7) } }
        try await Self.until("the late caller queues") { permits.usage.waiting == 7 }

        permits.release()
        for waiter in waiters { try await waiter.value }
        try await late.value
        #expect(order.value == [1, 2, 3, 4, 5, 6, 7])
        #expect(Self.usage(permits) == [0, 0])
    }

    @Test func aCancelledWaiterLeavesTheLineAndTakesNoPermit() async throws {
        let permits = TestPermits(limit: 1)
        try await permits.acquire()
        let cancelledRan = Box(false)
        let cancelled = Task { try await permits.withPermit { cancelledRan.value = true } }
        try await Self.until("the first waiter queues") { permits.usage.waiting == 1 }
        let nextRan = Box(false)
        let next = Task { try await permits.withPermit { nextRan.value = true } }
        try await Self.until("the second waiter queues") { permits.usage.waiting == 2 }

        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!cancelledRan.value, "a cancelled waiter ran its body")
        #expect(Self.usage(permits) == [1, 1], "the cancelled waiter is still queued or took a permit")

        // The permit goes to the waiter behind the cancelled one.
        permits.release()
        try await next.value
        #expect(nextRan.value)
        #expect(Self.usage(permits) == [0, 0])
    }

    @Test func aTaskCancelledBeforeItAsksTakesNoPermit() async throws {
        let permits = TestPermits(limit: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await permits.acquire()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Self.usage(permits) == [0, 0])
    }

    @Test func aHolderThatAsksAgainNestedDoesNotWaitOnItself() async throws {
        let permits = TestPermits(limit: 1)
        var depth = 0
        try await permits.withPermit {
            #expect(permits.isHeldByCurrentTask)
            try await permits.withPermit {
                depth = 2
                // A child task of the holder holds it too.
                try await withThrowingTaskGroup { group in
                    group.addTask { try await permits.withPermit { #expect(permits.isHeldByCurrentTask) } }
                    try await group.waitForAll()
                }
            }
            #expect(Self.usage(permits) == [1, 0], "a nested ask took a second permit")
        }
        #expect(depth == 2)
        #expect(!permits.isHeldByCurrentTask)
        #expect(Self.usage(permits) == [0, 0])
    }

    @Test func aBodyThatThrowsGivesItsPermitBack() async throws {
        struct Boom: Error {}
        let permits = TestPermits(limit: 1)
        await #expect(throws: Boom.self) { try await permits.withPermit { throw Boom() } }
        #expect(Self.usage(permits) == [0, 0])
    }

    @Test func theLimitComesFromTheEnvironmentElseTheCores() {
        #expect(TestPermits.configuredLimit(["CMUX_TEST_PERMITS": "3"]) == 3)
        let cores = TestPermits.configuredLimit([:])
        #expect(cores >= 1)
        #expect(TestPermits.configuredLimit(["CMUX_TEST_PERMITS": "0"]) == cores)
        #expect(TestPermits.configuredLimit(["CMUX_TEST_PERMITS": "lots"]) == cores)
    }
}
