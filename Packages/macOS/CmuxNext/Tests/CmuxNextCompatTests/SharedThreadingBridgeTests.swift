@testable import CmuxNextCompat
import CmuxThreading
import Foundation
import Testing

/// The bridge that makes the app's blocking detector CmuxThreading's hook: the detector installs
/// it once per process, a shared package's kind is recorded under the app kind of the same name, and in Debug a
/// shared `blockingCall` or a contended shared `Mutex` wait on the main thread is recorded like the app's own.
/// Each test that records binds its own table (``BlockingViolationTable/scoped``).
@Suite(.serialized)
struct SharedThreadingBridgeTests {
    @Test func theDetectorInstallsTheBridgeOncePerProcess() {
        _ = BlockingDetector.forProcess()
        #expect(BlockingCallHookSlot.process.isInstalled)
        #expect(!SharedThreadingBridge.installForProcess())
        _ = BlockingDetector.forProcess()
        #expect(BlockingCallHookSlot.process.isInstalled)
    }

    @Test func everySharedKindIsTheAppKindOfTheSameName() {
        for kind in CmuxThreading.BlockingKind.allCases {
            #expect(CmuxNextCompat.BlockingKind(kind).rawValue == kind.rawValue)
        }
    }

    @Test func theRunnerAdapterKeepsLevelsBehaviorsAndSites() {
        let levels = CmuxThreading.MayBlockPriority.allCases.map { CmuxNextCompat.MayBlockPriority($0) }
        #expect(levels == [.idle, .bestEffort, .userVisible, .userBlocking])
        let site = CmuxNextCompat.MayBlockCallSite(CmuxThreading.MayBlockCallSite(fileID: "Pkg/Store.swift", line: 12))
        #expect("\(site.fileID):\(site.line)" == "Pkg/Store.swift:12")
        #expect(CmuxNextCompat.MayBlockShutdown(.blockShutdown) == .blockShutdown)
        #expect(CmuxNextCompat.MayBlockShutdown(.continueOnShutdown) == .continueOnShutdown)
        #expect(CmuxNextCompat.MayBlockShutdown(.skipOnShutdown) == .skipOnShutdown)
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    @MainActor @Test func aSharedBlockingCallOnTheMainThreadIsRecordedAtItsSite() async {
        let table = BlockingViolationTable(mode: .record)
        let slot = BlockingCallHookSlot()
        slot.install(SharedThreadingBridge())
        BlockingViolationTable.$scoped.withValue(table) {
            #expect(slot.blockingCall(.sqlite, fileID: "CmuxHomeCore/HomeCache.swift", line: 41) { 7 } == 7)
        }
        await table.flush()
        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind) == [.sqlite])
        #expect(sites.map(\.location) == ["CmuxHomeCore/HomeCache.swift:41"])
    }

    @MainActor @Test func aLongMainThreadWaitForASharedMutexIsALockWait() async {
        SharedThreadingBridge.installForProcess()
        let clock = ReleasingClock(step: CmuxNextCompat.BlockingKind.lockWaitLimitNanos * 10)
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        let shared = SharedMutex()
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        clock.arm(release)
        Thread {
            shared.mutex.withLock { _ in
                held.signal()
                release.wait()
            }
        }.start()
        waitUntilHeld(held)
        BlockingViolationTable.$scoped.withValue(table) { shared.mutex.withLock { $0 += 1 } }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.map(\.kind) == [.lockWait])
        #expect(shared.mutex.withLock { $0 } == 1)
    }
    #endif
}

/// Waits for `semaphore` (the holder thread signals it once it has the lock); synchronous, because
/// `DispatchSemaphore.wait()` is unavailable in async code.
private nonisolated func waitUntilHeld(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

/// A CmuxThreading mutex threads can share (a mutex is not copyable, so a closure cannot capture it).
private nonisolated final class SharedMutex: Sendable {
    let mutex = CmuxThreading.Mutex(0)
}

/// A lock clock: the first read of a wait (its start) signals the semaphore ``arm(_:)`` set, which lets the thread
/// holding the mutex go; each read is `step` past the one before, so the wait measures `step`.
private nonisolated final class ReleasingClock: Sendable {
    private let state = CmuxNextCompat.Mutex((reads: UInt64(0), release: DispatchSemaphore?.none))
    private let step: UInt64

    init(step: UInt64) {
        self.step = step
    }

    func arm(_ release: DispatchSemaphore) {
        state.withLock { $0.release = release }
    }

    func read() -> UInt64 {
        let (reads, release) = state.withLock { state -> (UInt64, DispatchSemaphore?) in
            defer {
                state.reads += 1
                state.release = nil
            }
            return (state.reads, state.release)
        }
        release?.signal()
        return reads * step
    }
}
