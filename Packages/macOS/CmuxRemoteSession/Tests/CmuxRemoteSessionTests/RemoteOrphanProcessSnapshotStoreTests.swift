import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Remote orphan process snapshot sharing")
struct RemoteOrphanProcessSnapshotStoreTests {
    @Test("Concurrent reconnect owners share one native capture without subprocesses")
    func concurrentReconnectOwnersShareOneCapture() {
        let capturer = CountingOrphanProcessSnapshotCapturer(
            snapshots: [
                RemoteOrphanProcessSnapshot(
                    pid: 41,
                    parentPID: 1,
                    command: "/usr/bin/ssh user@alpha.test cmuxd-remote serve --stdio"
                ),
                RemoteOrphanProcessSnapshot(
                    pid: 42,
                    parentPID: 1,
                    command: "/usr/bin/ssh user@beta.test cmuxd-remote serve --stdio"
                ),
            ]
        )
        let store = RemoteOrphanProcessSnapshotStore(
            capturer: capturer,
            maximumAgeNanoseconds: 1_000_000_000,
            nowNanoseconds: { 100 }
        )
        let signals = RecordedSignals()
        let alphaReaper = RemoteOrphanedProcessReaper(store: store, signal: signals.record)
        let betaReaper = RemoteOrphanedProcessReaper(store: store, signal: signals.record)

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            if index.isMultiple(of: 2) {
                alphaReaper.reap(
                    destination: "user@alpha.test",
                    relayPort: nil,
                    persistentDaemonSlot: nil
                )
            } else {
                betaReaper.reap(
                    destination: "user@beta.test",
                    relayPort: nil,
                    persistentDaemonSlot: nil
                )
            }
        }

        let metrics = store.metricsSnapshot()
        #expect(capturer.captureCount == 1)
        #expect(metrics.captureStarted == 1)
        #expect(metrics.captureCompleted == 1)
        #expect(metrics.cacheReuse + metrics.inFlightReuse == 31)
        #expect(metrics.processLaunches == 0)
        #expect(signals.pids == Array(repeating: 41, count: 16) + Array(repeating: 42, count: 16))
    }

    @Test("Cache expiry is bounded by the injected monotonic clock")
    func cacheExpiryIsBounded() {
        let clock = MutableMonotonicClock(now: 10)
        let capturer = CountingOrphanProcessSnapshotCapturer(snapshots: [])
        let store = RemoteOrphanProcessSnapshotStore(
            capturer: capturer,
            maximumAgeNanoseconds: 5,
            nowNanoseconds: clock.read
        )

        _ = store.snapshot()
        _ = store.snapshot()
        #expect(capturer.captureCount == 1)

        clock.set(16)
        _ = store.snapshot()
        #expect(capturer.captureCount == 2)
    }
}

private final class CountingOrphanProcessSnapshotCapturer:
    RemoteOrphanProcessSnapshotCapturing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let snapshots: [RemoteOrphanProcessSnapshot]
    private var _captureCount = 0

    init(snapshots: [RemoteOrphanProcessSnapshot]) {
        self.snapshots = snapshots
    }

    var captureCount: Int { lock.withLock { _captureCount } }

    func capture() -> [RemoteOrphanProcessSnapshot] {
        lock.withLock { _captureCount += 1 }
        return snapshots
    }
}

private final class MutableMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64

    init(now: UInt64) {
        self.now = now
    }

    func read() -> UInt64 {
        lock.withLock { now }
    }

    func set(_ value: UInt64) {
        lock.withLock { now = value }
    }
}

private final class RecordedSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPIDs: [Int] = []

    var pids: [Int] { lock.withLock { recordedPIDs.sorted() } }

    func record(_ pid: Int, _ signal: Int32) -> Int32 {
        #expect(signal == SIGTERM)
        lock.withLock { recordedPIDs.append(pid) }
        return 0
    }
}
