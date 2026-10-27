@testable import CmuxNextCompat
import Darwin
import Dispatch
import Foundation
import Testing

/// Sync primitives on lanes (plans/cmux-next/chrome-parity/p02-threads.md, task 119): a `BackgroundWork` lane that
/// may block (`.files`, `.system`) may wait on the disk, but a wait for other work (a semaphore, a
/// `DispatchQueue.sync`, a contended `Mutex` past 2 ms, a synchronous reply) records a `lane-sync` site; a
/// dedicated thread or queue may do both. Chrome runs a `MayBlock()` task without `WithBaseSyncPrimitives()` under
/// `ScopedDisallowBaseSyncPrimitives` (base/task/thread_pool/task_tracker.cc).
///
/// `BlockingContext.runAsLane` is what `LaneScheduler` runs each lane item in (LaneBlockingContextTests checks the
/// real `.files` job). A dispatch block does not inherit task-locals, so each case binds its table on the thread
/// that makes the call.
@Suite(.serialized)
struct BlockingSyncPrimitiveTests {
    /// The class is sync-wait, ipc-reply and lock-wait; every other kind may run on a lane.
    @Test func theSyncPrimitiveClassIsTheWaitsForOtherWork() {
        #expect(BlockingKind.allCases.filter(\.isSyncPrimitive) == [.syncWait, .ipcReply, .lockWait])
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    // MARK: a lane (acceptance: blockingWait 1 lane-sync, file read 0)

    @Test func aSemaphoreWaitOnALaneRecordsOneLaneSyncSite() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let line = await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) { BlockingContext.runAsLane { laneSemaphoreWait() } }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.context) == [.laneSync])
        #expect(sites.map(\.kind) == [.syncWait])
        #expect(sites.map(\.seamKind) == [.syncWait])
        #expect(sites.map(\.count) == [1])
        #expect(sites.map(\.location) == ["CmuxNextCompatTests/BlockingSyncPrimitiveTests.swift:\(line)"])
    }

    @Test func aFileReadOnALaneRecordsNothing() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                BlockingContext.runAsLane { _ = try? Data(blockingContentsOf: URL(fileURLWithPath: "/etc/hosts")) }
            }
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// A synchronous reply is in the class too, and the sink sees the new site once, in its context.
    @Test func anIPCReplyOnALaneIsALaneSyncSiteTheSinkSeesOnce() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let recorder = SyncRecorder()
        BlockingDetector(table: table).install(sink: recorder)
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                BlockingContext.runAsLane {
                    for _ in 0..<2 { assertBlockingAllowed(.ipcReply, fileID: #fileID, line: 1) }
                }
            }
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.map(\.count) == [2])
        #expect(recorder.violations.map(\.context) == [.laneSync])
        #expect(recorder.violations.map(\.kind) == [.ipcReply])
        #expect(table.overflow(in: .laneSync) == 0)
    }

    /// A lane-sync call is timed like a pool one: its wall time adds to its site.
    @Test func aLaneSyncCallIsTimed() async {
        let clock = SyncStepClock(step: 3_000_000)
        let table = BlockingViolationTable(mode: .record, poolMode: .record, uptimeNanos: { clock.read() })
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                BlockingContext.runAsLane { blockingCall(.syncWait) {} }
            }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.totalNanos) == [3_000_000])
        #expect(sites.map(\.maxNanos) == [3_000_000])
        #expect(clock.reads == 2)
    }

    /// A lane's `Mutex` wait past the limit is a `lane-sync` `lock-wait` site with the wait as its time; under the
    /// limit it is not.
    @Test(arguments: [true, false])
    func aLongMutexWaitOnALaneIsALaneSyncSite(pastTheLimit: Bool) async {
        let step = pastTheLimit ? BlockingKind.lockWaitLimitNanos + 1 : BlockingKind.lockWaitLimitNanos - 1
        let (sites, reads) = await contendedMutexWait(step: step) { body in BlockingContext.runAsLane(body) }

        #expect(reads == 2)  // the wait was contended and timed
        if pastTheLimit {
            #expect(sites.map(\.context) == [.laneSync])
            #expect(sites.map(\.kind) == [.lockWait])
            #expect(sites.map(\.totalNanos) == [step])
        } else {
            #expect(sites.isEmpty)
        }
    }

    /// A `.cpu` lane item's `Mutex` wait past the limit is a `cpu-lane` `wrong-lane` site with seam kind
    /// `lock-wait`, as its other sync primitives are; under the limit it is not.
    @Test(arguments: [true, false])
    func aLongMutexWaitOnTheCPULaneIsAWrongLaneSite(pastTheLimit: Bool) async {
        let step = pastTheLimit ? BlockingKind.lockWaitLimitNanos + 1 : BlockingKind.lockWaitLimitNanos - 1
        let (sites, reads) = await contendedMutexWait(step: step) { body in BlockingContext.runAsCPULane(body) }

        #expect(reads == 2)  // the wait was contended and timed
        if pastTheLimit {
            #expect(sites.map(\.context) == [.cpuLane])
            #expect(sites.map(\.kind) == [.wrongLane])
            #expect(sites.map(\.seamKind) == [.lockWait])
            #expect(sites.map(\.count) == [1])
            #expect(sites.map(\.totalNanos) == [step])
        } else {
            #expect(sites.isEmpty)
        }
    }

    // MARK: where sync primitives are allowed (acceptance: dedicated 0)

    @Test func aSemaphoreWaitOnANamedSerialQueueRecordsNothing() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        _ = await onQueue(DispatchQueue(label: "com.cmuxterm.tests.sync-primitive-serial")) {
            BlockingViolationTable.$scoped.withValue(table) { laneSemaphoreWait() }
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    @Test func aSemaphoreWaitOnANamedThreadRecordsNothing() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                pthread_setname_np("com.cmuxterm.tests.sync-primitive-thread")
                BlockingViolationTable.$scoped.withValue(table) { _ = laneSemaphoreWait() }
                done.resume()
            }
            thread.start()
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// `allowBlocking` inside a lane item allows its sync primitives (Chrome's `ScopedAllowBaseSyncPrimitives`).
    @Test func anAllowedWaitInALaneItemRecordsNothing() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                BlockingContext.runAsLane {
                    allowBlocking(BlockingAllowance(reviewed: "test")) { _ = laneSemaphoreWait() }
                }
            }
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// The lane-sync table is its own: resetting zeroes its counts, and its overflow is in the total.
    @Test func resetCountsZeroesTheLaneSyncSites() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) { BlockingContext.runAsLane { _ = laneSemaphoreWait() } }
        }
        await table.flush()
        BlockingDetector(table: table).resetCounts()
        #expect(BlockingDetector(table: table).sites.map(\.count) == [0])
        #expect(BlockingDetector(table: table).overflow == 0)
    }

    #if DEBUG
    /// A lane-sync call never traps, whatever the main and pool modes are.
    @Test func aLaneSyncCallNeverTraps() async {
        await #expect(processExitsWith: .success) {
            let table = BlockingViolationTable(mode: .trap, poolMode: .trap)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    BlockingViolationTable.$scoped.withValue(table) { BlockingContext.runAsLane { _ = laneSemaphoreWait() } }
                    done.resume()
                }
            }
        }
    }
    #endif
    #endif
}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// Runs `body` on `queue` and returns its result.
private nonisolated func onQueue<T: Sendable>(_ queue: DispatchQueue, _ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
        queue.async { done.resume(returning: body()) }
    }
}

/// One checked wait on a semaphore that was already signaled (it returns at once); returns the line of the call.
@discardableResult
private nonisolated func laneSemaphoreWait() -> UInt {
    let semaphore = DispatchSemaphore(value: 0)
    semaphore.signal()
    let line: UInt = #line + 1
    semaphore.blockingWait()
    return line
}

/// One contended `Mutex` wait inside `lane` (a lane mark) on a utility root queue, timed by a clock that moves
/// `step` per read; returns the table's sites and the clock's reads.
private nonisolated func contendedMutexWait(
    step: UInt64, in lane: @escaping @Sendable (() -> Void) -> Void
) async -> (sites: [BlockingSite], reads: Int) {
    let clock = SyncStepClock(step: step)
    let table = BlockingViolationTable(mode: .record, poolMode: .record, uptimeNanos: { clock.read() })
    let shared = SyncSharedCount()
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    clock.arm(release)
    Thread {
        shared.mutex.withLock { _ in
            held.signal()
            release.wait()
        }
    }.start()
    await onQueue(.global(qos: .utility)) {
        held.wait()  // the holder has the lock
        BlockingViolationTable.$scoped.withValue(table) {
            lane { shared.mutex.withLock { $0 += 1 } }
        }
    }
    await table.flush()
    return (BlockingDetector(table: table).sites, clock.reads)
}

/// A mutex threads can share (a `Mutex` is not copyable, so a closure cannot capture it).
private nonisolated final class SyncSharedCount: Sendable {
    let mutex = Mutex(0)
}

/// A sink that keeps what it is given.
private nonisolated final class SyncRecorder: BlockingViolationSink, Sendable {
    private let seen = Mutex<[BlockingViolation]>([])
    var violations: [BlockingViolation] { seen.withLock { $0 } }

    func record(_ violation: BlockingViolation) {
        seen.withLock { $0.append(violation) }
    }
}

/// A clock that moves `step` nanoseconds per read, so each timed call (two reads) measures `step`. Its first read
/// after ``arm(_:)`` signals the armed semaphore, which lets the thread holding a mutex go.
private nonisolated final class SyncStepClock: Sendable {
    private let state = Mutex((reads: 0, now: UInt64(0), release: DispatchSemaphore?.none))
    private let step: UInt64

    init(step: UInt64) {
        self.step = step
    }

    var reads: Int { state.withLock { $0.reads } }

    func arm(_ release: DispatchSemaphore) {
        state.withLock { $0.release = release }
    }

    func read() -> UInt64 {
        let (now, release) = state.withLock { state in
            state.reads += 1
            state.now += step
            defer { state.release = nil }
            return (state.now, state.release)
        }
        release?.signal()
        return now
    }
}
#endif
