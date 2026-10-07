@testable import CmuxNextControl
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1))) struct MainActorWorkQueueTests {
    @Test func failsFastWithBusyBeyondTheLimit() async throws {
        let frames = ManualFrameSource()
        let queue = MainActorWorkQueue(limits: .init(maxPending: 2), frameSource: frames)
        let deadline = ContinuousClock.now + .seconds(5)
        async let first: Int = queue.run(connection: ControlConnectionID(rawValue: 1), method: "a", deadline: deadline) { 1 }
        async let second: Int = queue.run(connection: ControlConnectionID(rawValue: 2), method: "b", deadline: deadline) { 2 }
        while queue.stats.pending < 2 { await Task.yield() }
        let started = ContinuousClock.now
        await #expect(throws: ControlError.busy(pending: 2, limit: 2)) {
            _ = try await queue.run(connection: ControlConnectionID(rawValue: 3), method: "c", deadline: deadline) { 3 }
        }
        #expect(ContinuousClock.now - started < .milliseconds(100))
        #expect(queue.stats.rejectedBusy == 1)
        await frames.fire()
        #expect(try await first + second == 3)
    }

    @Test func aRequestThatTimesOutWhileQueuedNeverRuns() async throws {
        let frames = ManualFrameSource()
        let queue = MainActorWorkQueue(frameSource: frames)
        let ran = Shared(false)
        let started = ContinuousClock.now
        await #expect(throws: ControlError.self) {
            try await queue.run(method: "workspace.create", deadline: .now + .milliseconds(100)) { ran.withLock { $0 = true } }
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(queue.stats.expired == 1)
        // The main thread comes back: the expired item is dropped, not run.
        await frames.fire()
        let didRun = ran.withLock { $0 }
        #expect(!didRun)
        #expect(queue.stats.executed == 0)
    }

    @Test func connectionsAreServedRoundRobin() async throws {
        let frames = ManualFrameSource()
        // A zero budget runs exactly one item per frame.
        let queue = MainActorWorkQueue(limits: .init(frameBudget: .zero), frameSource: frames)
        let order = Shared<[String]>([])
        let deadline = ContinuousClock.now + .seconds(10)
        let flood = ControlConnectionID(rawValue: 1)
        let polite = ControlConnectionID(rawValue: 2)
        let tasks = (0..<5).map { index in
            Task { try await queue.run(connection: flood, method: "flood", deadline: deadline) { order.withLock { $0.append("flood\(index)") } } }
        }
        while queue.stats.pending < 5 { await Task.yield() }
        let politeTask = Task { try await queue.run(connection: polite, method: "polite", deadline: deadline) { order.withLock { $0.append("polite") } } }
        while queue.stats.pending < 6 { await Task.yield() }
        while queue.stats.pending > 0 {
            await frames.fire()
            await Task.yield()
        }
        for task in tasks { try await task.value }
        try await politeTask.value
        let ran = order.withLock { $0 }
        #expect(ran.count == 6)
        // The polite client waits behind at most one flood item, not all five.
        #expect(ran.firstIndex(of: "polite")! <= 1)
    }

    @Test func eachFrameStopsAtTheBudget() async throws {
        let frames = ManualFrameSource()
        let queue = MainActorWorkQueue(limits: .init(frameBudget: .milliseconds(4)), frameSource: frames)
        let deadline = ContinuousClock.now + .seconds(10)
        let tasks = (0..<10).map { index in
            Task { try await queue.run(connection: ControlConnectionID(rawValue: UInt64(index + 1)), method: "w", deadline: deadline) {
                spin(for: .milliseconds(3))
            } }
        }
        while queue.stats.pending < 10 { await Task.yield() }
        await frames.fire()
        // 3 ms items against a 4 ms budget: at most two per frame (one if
        // the thread was preempted mid-item).
        #expect((1...2).contains(queue.stats.executed))
        while queue.stats.pending > 0 {
            await frames.fire()
            await Task.yield()
        }
        for task in tasks { try await task.value }
        #expect(queue.stats.frames >= 5)
        #expect(queue.stats.executed == 10)
    }
}

/// State the test shares with queued work. `MainActorWorkQueue.run` takes
/// `@escaping @Sendable` work, and an escaping closure cannot capture a
/// noncopyable local `Atomic` or `Mutex`; a Sendable class that owns one can.
private final class Shared<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func withLock<R>(_ body: (inout sending Value) -> sending R) -> sending R { mutex.withLock(body) }
}
