import Foundation
import Testing

@testable import CmuxFoundation

/// A clock whose `sleep(for:)` suspends until the test releases it, so the
/// watcher's coalescing throttle can be advanced with no real waiting.
private actor GateClock: FileWatchClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sleepers.append(continuation)
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Number of throttle delays currently parked on the clock.
    var sleeperCount: Int { sleepers.count }

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
        let watcher = RecursivePathWatcher(testThrottleClock: clock)
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
        let watcher = RecursivePathWatcher(testThrottleClock: clock)
        var iterator = watcher.events.makeAsyncIterator()

        await watcher.stop()
        await watcher.simulateFileSystemEventForTesting()
        let next: Void? = await iterator.next()
        #expect(next == nil)
        #expect(await clock.sleeperCount == 0)
    }
}
