import CoreServices
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
        let first: FileWatchEventIdentity? = await iterator.next()
        #expect(first != nil)

        // Window 2: the throttle re-arms after the previous flush.
        for _ in 0..<3 {
            await watcher.simulateFileSystemEventForTesting()
        }
        await clock.waitForSleeper()
        #expect(await clock.sleeperCount == 1)

        await clock.releaseOne()
        let second: FileWatchEventIdentity? = await iterator.next()
        #expect(second != nil)

        await watcher.stop()
        let afterStop: FileWatchEventIdentity? = await iterator.next()
        #expect(afterStop == nil)
    }

    /// Events delivered after `stop()` produce no further yields.
    @Test func eventsAfterStopAreIgnored() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(testThrottleClock: clock)
        var iterator = watcher.events.makeAsyncIterator()

        await watcher.stop()
        await watcher.simulateFileSystemEventForTesting()
        let next: FileWatchEventIdentity? = await iterator.next()
        #expect(next == nil)
        #expect(await clock.sleeperCount == 0)
    }

    @Test func eventsEmitLatestStableIDFromThrottleWindow() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(testThrottleClock: clock)
        var iterator = watcher.events.makeAsyncIterator()

        await watcher.simulateFileSystemEventForTesting(
            id: FileWatchEventID(rawValue: 41)
        )
        await watcher.simulateFileSystemEventForTesting(
            id: FileWatchEventID(rawValue: 43)
        )
        await watcher.simulateFileSystemEventForTesting(
            id: FileWatchEventID(rawValue: 42)
        )
        await clock.waitForSleeper()
        await clock.releaseOne()

        #expect(await iterator.next() == .stable(FileWatchEventID(rawValue: 43)))
        await watcher.stop()
    }

    @Test func droppedAndWrappedBatchesStayConservative() async {
        let userDropped = FileSystemEventStream.eventIdentity(
            latestEventID: 100,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
        )
        let kernelDropped = FileSystemEventStream.eventIdentity(
            latestEventID: 101,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        )
        let mustScan = FileSystemEventStream.eventIdentity(
            latestEventID: 102,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        )
        let wrapped = FileSystemEventStream.eventIdentity(
            latestEventID: 1,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        )

        #expect(userDropped == .mustRescan)
        #expect(kernelDropped == .mustRescan)
        #expect(mustScan == .mustRescan)
        #expect(wrapped == .eventIDsWrapped)
    }

    @Test func conservativeIdentityDominatesThrottleWindow() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(testThrottleClock: clock)
        var iterator = watcher.events.makeAsyncIterator()

        await watcher.simulateFileSystemEventForTesting(
            id: FileWatchEventID(rawValue: 50)
        )
        await watcher.simulateFileSystemEventForTesting(identity: .mustRescan)
        await watcher.simulateFileSystemEventForTesting(
            id: FileWatchEventID(rawValue: 51)
        )
        await clock.waitForSleeper()
        await clock.releaseOne()
        #expect(await iterator.next() == .mustRescan)

        await watcher.simulateFileSystemEventForTesting(
            id: FileWatchEventID(rawValue: 52)
        )
        await watcher.simulateFileSystemEventForTesting(identity: .eventIDsWrapped)
        await clock.waitForSleeper()
        await clock.releaseOne()
        #expect(await iterator.next() == .eventIDsWrapped)

        await watcher.simulateFileSystemEventForTesting(
            id: FileWatchEventID(rawValue: 1)
        )
        await clock.waitForSleeper()
        await clock.releaseOne()
        #expect(await iterator.next() == .eventIDsWrapped)
        await watcher.stop()
    }

    @Test func unconsumedStreamRetainsOnlyNewestStableWatermark() async {
        let clock = GateClock()
        let watcher = RecursivePathWatcher(testThrottleClock: clock)

        for rawID in 1...100 {
            await watcher.simulateFileSystemEventForTesting(
                id: FileWatchEventID(rawValue: UInt64(rawID))
            )
            await clock.waitForSleeper()
            await clock.releaseOne()
            await watcher.waitForThrottleFlushForTesting()
        }

        var iterator = watcher.events.makeAsyncIterator()
        #expect(await iterator.next() == .stable(FileWatchEventID(rawValue: 100)))
        await watcher.stop()
        #expect(await iterator.next() == nil)
    }
}
