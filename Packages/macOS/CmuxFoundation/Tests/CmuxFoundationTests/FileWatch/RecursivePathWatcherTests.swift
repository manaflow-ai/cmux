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

private final class ManualFileWatchEventSource: FileWatchEventSource, @unchecked Sendable {
    let events: AsyncStream<FileWatchEventIdentity>
    private let continuation: AsyncStream<FileWatchEventIdentity>.Continuation

    init() {
        (events, continuation) = AsyncStream<FileWatchEventIdentity>.makeStream()
    }

    func send(_ identity: FileWatchEventIdentity) {
        continuation.yield(identity)
    }

    func stop() {
        continuation.finish()
    }
}

@discardableResult
private func yieldPendingIdentity(
    from state: inout FileWatchEventCoalescingState,
    into continuation: AsyncStream<FileWatchEventIdentity>.Continuation
) -> FileWatchEventIdentity? {
    guard let identity = state.takePendingIdentity() else { return nil }
    state.recordYield(continuation.yield(identity))
    return identity
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

    @Test func burstCoalescingStateArmsOnceAndRearmsAfterFlush() {
        var state = FileWatchEventCoalescingState()

        let didArmFirstWindow = state.record(.stable(FileWatchEventID(rawValue: 1)))
        #expect(didArmFirstWindow)
        for rawID in 2...5 {
            let didRearm = state.record(.stable(FileWatchEventID(rawValue: UInt64(rawID))))
            #expect(!didRearm)
        }
        let firstWindowIdentity = state.takePendingIdentity()
        let didArmSecondWindow = state.record(.stable(FileWatchEventID(rawValue: 6)))
        #expect(firstWindowIdentity == .stable(FileWatchEventID(rawValue: 5)))
        #expect(didArmSecondWindow)
    }

    /// The transport pump, virtual clock, and output stream share the same
    /// production path as FSEvents. A completed window must permit a later event
    /// to arm a fresh delay.
    @Test func sourceEventsFlowThroughThrottleAndRearm() async {
        let clock = GateClock()
        let source = ManualFileWatchEventSource()
        let watcher = RecursivePathWatcher(
            watchedPaths: ["/manual"],
            eventSource: source,
            clock: clock
        )
        var iterator = watcher.events.makeAsyncIterator()

        source.send(.stable(FileWatchEventID(rawValue: 1)))
        await clock.waitForSleeper()
        #expect(await clock.sleeperCount == 1)
        await clock.releaseOne()
        #expect(await iterator.next() == .stable(FileWatchEventID(rawValue: 1)))

        source.send(.stable(FileWatchEventID(rawValue: 2)))
        await clock.waitForSleeper()
        #expect(await clock.sleeperCount == 1)
        await clock.releaseOne()
        #expect(await iterator.next() == .stable(FileWatchEventID(rawValue: 2)))

        await watcher.stop()
        #expect(await iterator.next() == nil)
    }

    /// Events delivered after `stop()` produce no further yields.
    @Test func eventsAfterStopAreIgnored() async {
        let clock = GateClock()
        let source = ManualFileWatchEventSource()
        let watcher = RecursivePathWatcher(
            watchedPaths: ["/manual"],
            eventSource: source,
            clock: clock
        )
        var iterator = watcher.events.makeAsyncIterator()

        await watcher.stop()
        source.send(.stable(FileWatchEventID(rawValue: 1)))
        let next: FileWatchEventIdentity? = await iterator.next()
        #expect(next == nil)
        #expect(await clock.sleeperCount == 0)
    }

    @Test func eventsEmitLatestStableIDFromThrottleWindow() {
        var state = FileWatchEventCoalescingState()

        _ = state.record(.stable(FileWatchEventID(rawValue: 41)))
        _ = state.record(.stable(FileWatchEventID(rawValue: 43)))
        _ = state.record(.stable(FileWatchEventID(rawValue: 42)))

        let identity = state.takePendingIdentity()
        #expect(identity == .stable(FileWatchEventID(rawValue: 43)))
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

    @Test func conservativeIdentityDominatesOnlyUntilBufferedResetIsObserved() async {
        var state = FileWatchEventCoalescingState()
        let (events, continuation) = AsyncStream<FileWatchEventIdentity>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        var iterator = events.makeAsyncIterator()

        _ = state.record(.stable(FileWatchEventID(rawValue: 50)))
        _ = state.record(.mustRescan)
        _ = state.record(.stable(FileWatchEventID(rawValue: 51)))
        let firstReset = yieldPendingIdentity(from: &state, into: continuation)
        #expect(firstReset == .mustRescan)
        #expect(await iterator.next() == .mustRescan)

        _ = state.record(.stable(FileWatchEventID(rawValue: 52)))
        let repeatedReset = yieldPendingIdentity(from: &state, into: continuation)
        #expect(repeatedReset == .mustRescan)
        // Repeat the conservative signal once after the consumer drains it. This
        // acknowledges the bounded AsyncStream buffer without losing a reset to
        // a newer stable watermark.
        #expect(await iterator.next() == .mustRescan)

        _ = state.record(.stable(FileWatchEventID(rawValue: 53)))
        let resumedStableIdentity = yieldPendingIdentity(from: &state, into: continuation)
        #expect(resumedStableIdentity == .stable(FileWatchEventID(rawValue: 53)))
        #expect(await iterator.next() == .stable(FileWatchEventID(rawValue: 53)))

        _ = state.record(.stable(FileWatchEventID(rawValue: 54)))
        _ = state.record(.eventIDsWrapped)
        let wrappedReset = yieldPendingIdentity(from: &state, into: continuation)
        #expect(wrappedReset == .eventIDsWrapped)
        #expect(await iterator.next() == .eventIDsWrapped)

        _ = state.record(.stable(FileWatchEventID(rawValue: 1)))
        let repeatedWrappedReset = yieldPendingIdentity(from: &state, into: continuation)
        #expect(repeatedWrappedReset == .eventIDsWrapped)
        #expect(await iterator.next() == .eventIDsWrapped)

        _ = state.record(.stable(FileWatchEventID(rawValue: 2)))
        let resumedWrappedStableIdentity = yieldPendingIdentity(
            from: &state,
            into: continuation
        )
        #expect(resumedWrappedStableIdentity == .stable(FileWatchEventID(rawValue: 2)))
        #expect(await iterator.next() == .stable(FileWatchEventID(rawValue: 2)))
        continuation.finish()
        #expect(await iterator.next() == nil)
    }

    @Test func unconsumedStreamRetainsOnlyNewestStableWatermark() async {
        var state = FileWatchEventCoalescingState()
        let (events, continuation) = AsyncStream<FileWatchEventIdentity>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        for rawID in 1...100 {
            _ = state.record(.stable(FileWatchEventID(rawValue: UInt64(rawID))))
            _ = yieldPendingIdentity(from: &state, into: continuation)
        }

        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .stable(FileWatchEventID(rawValue: 100)))
        continuation.finish()
        #expect(await iterator.next() == nil)
    }
}
