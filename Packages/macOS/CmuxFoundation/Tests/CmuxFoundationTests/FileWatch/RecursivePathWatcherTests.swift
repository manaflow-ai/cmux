import Foundation
import Testing

@testable import CmuxFoundation

/// A clock whose `sleep(for:)` suspends until the test releases it, so the
/// watcher's coalescing throttle can be advanced with no real waiting.
private actor GateClock: FileWatchClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            requestedDurations.append(duration)
            sleepers.append(continuation)
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Number of throttle delays currently parked on the clock.
    var sleeperCount: Int { sleepers.count }

    /// Durations requested by the watcher, in arrival order.
    var sleepDurations: [Duration] { requestedDurations }

    /// Suspends until at least one sleeper has registered.
    func waitForSleeper() async {
        if !sleepers.isEmpty { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            arrivalWaiters.append(continuation)
        }
    }

    /// Releases the oldest parked throttle delay.
    func releaseOne() {
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().resume()
    }
}

private actor WatchRecheckCounter {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        count += 1
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitForFirstRecheck() async {
        if count > 0 { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    var recheckCount: Int { count }
}

extension RecursivePathWatcher {
    fileprivate func simulateFileSystemEventForTesting(
        paths: [String] = [],
        requiresFullRescan: Bool = false
    ) {
        receive(
            FileSystemEventBatch(
                paths: paths,
                requiresFullRescan: requiresFullRescan
            ))
    }
}

@Suite struct RecursivePathWatcherTests {
    @Test func emptyPathsFailsInitialization() {
        let watcher = RecursivePathWatcher(paths: [])
        #expect(watcher == nil)
    }

    @Test func realDirectoryStartsAndStops() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-file-watch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watcher = RecursivePathWatcher(paths: [directory.path])
        #expect(watcher != nil)
        #expect(watcher?.watchedPaths == [directory.path])
        await watcher?.stop()
    }

    /// A burst of events inside one throttle window coalesces into a single
    /// yield, a fresh event re-arms the throttle, and `stop()` finishes the
    /// stream. This is the leading-edge behavior the watcher provides: react once
    /// per window during a storm, never once per event and never only after
    /// changes stop.
    @Test func burstCoalescesAndThrottleRearms() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(clock: clock)
        var iterator = watcher.events.makeAsyncIterator()

        // Window 1: five events, but only the first arms the throttle.
        for _ in 0..<5 {
            await watcher.simulateFileSystemEventForTesting()
        }
        await clock.waitForSleeper()
        #expect(await clock.sleeperCount == 1)

        await clock.releaseOne()
        let first: Void? = await iterator.next()
        #expect(first != nil)

        // Window 2: the throttle re-arms after the previous flush.
        for _ in 0..<3 {
            await watcher.simulateFileSystemEventForTesting()
        }
        await clock.waitForSleeper()
        #expect(await clock.sleeperCount == 1)

        await clock.releaseOne()
        let second: Void? = await iterator.next()
        #expect(second != nil)

        await watcher.stop()
        let afterStop: Void? = await iterator.next()
        #expect(afterStop == nil)
    }

    /// Events delivered after `stop()` produce no further yields.
    @Test func eventsAfterStopAreIgnored() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(clock: clock)
        var iterator = watcher.events.makeAsyncIterator()

        await watcher.stop()
        await watcher.simulateFileSystemEventForTesting()
        let next: Void? = await iterator.next()
        #expect(next == nil)
        #expect(await clock.sleeperCount == 0)
    }

    @Test func pathEventsAggregateAndDeduplicatePaths() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(clock: clock)
        var iterator = watcher.pathEvents.makeAsyncIterator()

        await watcher.simulateFileSystemEventForTesting(paths: ["/repo/build/output.js"])
        await watcher.simulateFileSystemEventForTesting(paths: ["/repo/Sources/App.swift"])
        await watcher.simulateFileSystemEventForTesting(paths: ["/repo/Sources/App.swift"])
        await clock.waitForSleeper()
        await clock.releaseOne()

        let change = await iterator.next()
        #expect(change == RecursivePathChange(paths: [
            "/repo/Sources/App.swift",
            "/repo/build/output.js",
        ]))
        await watcher.stop()
    }

    @Test func fullRescanMarkerSurvivesCoalescing() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(clock: clock)
        var iterator = watcher.pathEvents.makeAsyncIterator()

        await watcher.simulateFileSystemEventForTesting(
            paths: ["/repo/partial"],
            requiresFullRescan: true
        )
        await clock.waitForSleeper()
        await clock.releaseOne()

        let change = await iterator.next()
        #expect(change?.paths == [])
        #expect(change?.requiresFullRescan == true)
        await watcher.stop()
    }

    @Test func droppedPathDetailBecomesFullRescanMarker() async {
        let (events, continuation) = AsyncStream<RecursivePathChange>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        RecursivePathWatcher.yieldPathChangePreservingRescan(
            RecursivePathChange(paths: ["/repo/first.swift"]),
            to: continuation
        )
        RecursivePathWatcher.yieldPathChangePreservingRescan(
            RecursivePathChange(paths: ["/repo/second.swift"]),
            to: continuation
        )

        var iterator = events.makeAsyncIterator()
        let change = await iterator.next()
        #expect(change == RecursivePathChange(paths: [], requiresFullRescan: true))
        continuation.finish()
    }

    @Test func callerControlsThrottleCeiling() async {
        let clock = GateClock()
        let interval: Duration = .seconds(30)
        let watcher = RecursivePathWatcher(
            clock: clock,
            throttleInterval: interval
        )

        await watcher.simulateFileSystemEventForTesting()
        await clock.waitForSleeper()
        #expect(await clock.sleepDurations == [interval])
        await watcher.stop()
    }

    @Test func eventFilterRejectsIrrelevantBatchesBeforeDebounce() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(clock: clock) { change in
            change.paths.contains { $0.hasPrefix("/repo/Sources/") }
        }

        await watcher.simulateFileSystemEventForTesting(paths: ["/repo/node_modules/output.js"])
        #expect(await clock.sleeperCount == 0)

        await watcher.simulateFileSystemEventForTesting(paths: ["/repo/Sources/App.swift"])
        await clock.waitForSleeper()
        #expect(await clock.sleeperCount == 1)
        await watcher.stop()
    }

    /// A rapid notification burst drives exactly one consumer re-check, not one
    /// re-check per filesystem callback.
    @Test func rapidEventsCoalesceIntoOneConsumerRecheck() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(clock: clock)
        let counter = WatchRecheckCounter()
        let consumer = Task {
            for await _ in watcher.events {
                await counter.record()
            }
        }

        for _ in 0..<25 {
            await watcher.simulateFileSystemEventForTesting()
        }
        await clock.waitForSleeper()
        await clock.releaseOne()
        await counter.waitForFirstRecheck()
        await watcher.stop()
        await consumer.value

        #expect(await counter.recheckCount == 1)
    }
}
