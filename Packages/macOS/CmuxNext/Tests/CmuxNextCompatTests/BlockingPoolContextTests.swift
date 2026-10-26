@testable import CmuxNextCompat
import Darwin
import Dispatch
import Foundation
import Testing

/// The blocking detector off the main thread (plans/cmux-next/chrome-parity/p02-threads.md, task 005): a seam on
/// a shared pool thread (the Swift cooperative pool, a GCD root queue) is a violation, recorded at its own `pool`
/// site; on a lane slot, a named serial queue, a named thread or inside `allowBlocking` it is not. Chrome runs a
/// pool task without `MayBlock()` under `ScopedDisallowBlocking` (base/task/thread_pool/task_tracker.cc).
///
/// A detached task or a dispatch block does not inherit task-locals, so each case binds its table on the thread
/// that makes the call.
@Suite(.serialized)
struct BlockingPoolContextTests {
    /// The names `debug.blocking` and the hang reports use never change.
    @Test func theContextsKeepTheirNames() {
        #expect(BlockingContext.allCases.map(\.rawValue) == ["main", "pool", "lane", "dedicated", "cpu-lane", "lane-sync"])
    }

    /// GCD root queues (and the cooperative pool's queues, which share the prefix) are pools; a named queue (one
    /// that ends in `.cooperative` too), the main queue and an empty label are not.
    @Test(arguments: [
        ("com.apple.root.default-qos", true),
        ("com.apple.root.user-initiated-qos.overcommit", true),
        ("com.apple.root.user-initiated-qos.cooperative", true),
        ("com.example.executor.cooperative", false),
        ("com.cmuxterm.next.work.files.userBlocking", false),
        ("com.apple.main-thread", false),
        ("com.apple.root", false),
        ("cooperative", false),
        ("", false),
    ])
    func aQueueLabelIsAPoolByItsPrefixOrSuffix(label: String, isPool: Bool) {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        #expect(label.withCString { BlockingContext.isPoolLabel($0) } == isPool)
        #endif
    }

    #if DEBUG || CMUX_BLOCKING_CHECKS
    // MARK: what the calling thread is

    @Test func aDetachedTaskRunsOnThePool() async {
        #expect(await Task.detached { BlockingContext.current() }.value == .pool)
    }

    @Test func aGlobalQueueIsThePool() async {
        #expect(await onQueue(.global(qos: .utility)) { BlockingContext.current() } == .pool)
    }

    @Test func aNamedSerialQueueIsDedicated() async {
        #expect(await onQueue(DispatchQueue(label: "com.cmuxterm.tests.pool-context")) { BlockingContext.current() } == .dedicated)
    }

    /// A named serial queue that targets a root queue is still its own label, so still dedicated.
    @Test func aNamedQueueThatTargetsAGlobalQueueIsDedicated() async {
        let queue = DispatchQueue(label: "com.cmuxterm.tests.pool-context-target", target: .global(qos: .utility))
        #expect(await onQueue(queue) { BlockingContext.current() } == .dedicated)
    }

    /// A thread with a pthread name (every cmux `Thread` is named) is dedicated; it reads the default root
    /// queue's label, so the name is what tells it from a pool worker.
    @Test func aNamedThreadIsDedicated() async {
        let context = await withCheckedContinuation { (done: CheckedContinuation<BlockingContext, Never>) in
            let thread = Thread {
                pthread_setname_np("com.cmuxterm.tests.pool-context-thread")
                done.resume(returning: BlockingContext.current())
            }
            thread.start()
        }
        #expect(context == .dedicated)
    }

    /// The first check on a named thread marks it dedicated, so later checks are one thread-specific read and
    /// never read the name again; a pool worker keeps that it has no name.
    @Test func theFirstCheckKeepsTheThreadsNameInItsFlags() async {
        let named = await withCheckedContinuation { (done: CheckedContinuation<[BlockingContext.Mark?], Never>) in
            let thread = Thread {
                pthread_setname_np("com.cmuxterm.tests.pool-context-cached")
                let before = BlockingThreadFlags.load().mark
                _ = BlockingContext.current()
                done.resume(returning: [before, BlockingThreadFlags.load().mark])
            }
            thread.start()
        }
        #expect(named == [nil, .dedicated])

        let worker = await onQueue(.global(qos: .utility)) { () -> (BlockingContext, Bool, BlockingContext.Mark?) in
            let context = BlockingContext.current()
            return (context, BlockingThreadFlags.load().isUnnamed, BlockingThreadFlags.load().mark)
        }
        #expect(worker.0 == .pool)
        #expect(worker.1)
        #expect(worker.2 == nil)
    }

    /// A mark wins over the label while its scope runs, and the inner scope wins until it returns.
    @Test func aMarkWinsOverThePoolLabelForItsScope() async {
        let seen = await onQueue(.global(qos: .utility)) { () -> [BlockingContext] in
            let lane = BlockingContext.run(as: .lane) {
                (BlockingContext.current(), BlockingContext.run(as: .dedicated) { BlockingContext.current() },
                 BlockingContext.current())
            }
            return [lane.0, lane.1, lane.2, BlockingContext.current()]
        }
        #expect(seen == [.lane, .dedicated, .lane, .pool])
    }

    @MainActor @Test func theMainThreadIsMainEvenWhenMarked() {
        #expect(BlockingContext.current() == .main)
        #expect(BlockingContext.run(as: .lane) { BlockingContext.current() } == .main)
    }

    // MARK: seams on the pool are recorded (acceptance: 1 pool site each)

    @Test func aSeamInADetachedTaskRecordsOnePoolSite() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let line = await Task.detached { BlockingViolationTable.$scoped.withValue(table) { checkedRead() } }.value
        await table.flush()

        #expect(BlockingDetector(table: table).sites.map(\.context) == [.pool])
        #expect(BlockingDetector(table: table).sites.map(\.location) == ["CmuxNextCompatTests/BlockingPoolContextTests.swift:\(line)"])
        #expect(BlockingDetector(table: table).sites.map(\.count) == [1])
        #expect(BlockingDetector(table: table).sites.map(\.kind) == [.fileIO])
    }

    @Test func aSeamOnAGlobalQueueRecordsOnePoolSite() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        _ = await onQueue(.global(qos: .userInitiated)) { BlockingViolationTable.$scoped.withValue(table) { checkedRead() } }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.map(\.context) == [.pool])
        #expect(BlockingDetector(table: table).sites.map(\.count) == [1])
    }

    /// Each pool call adds to its site; the new site reaches the sink once, with its context.
    @Test func repeatsCountAtOneSiteAndTheSinkSeesItOnce() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let recorder = PoolRecorder()
        BlockingDetector(table: table).install(sink: recorder)
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                for _ in 0..<3 { _ = checkedRead() }  // one site
            }
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.map(\.count) == [3])
        #expect(recorder.violations.map(\.context) == [.pool])
        #expect(recorder.violations.map(\.kind) == [.fileIO])
    }

    /// A pool call is timed like a main-thread one, and only the outermost timed call on the thread is timed.
    @Test func onlyTheOutermostPoolCallIsTimed() async {
        let clock = PoolStepClock(step: 2_000_000)
        let table = BlockingViolationTable(mode: .record, poolMode: .record, uptimeNanos: { clock.read() })
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                blockingCall(.syncWait) { _ = checkedRead() }
            }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind) == [.syncWait, .fileIO])
        #expect(sites.map(\.totalNanos) == [2_000_000, 0])
        #expect(sites.map(\.count) == [1, 1])
        #expect(clock.reads == 2)
    }

    /// The same line on the main thread and on the pool is two sites, one per context.
    @MainActor @Test func oneLineOnMainAndOnThePoolIsTwoSites() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        BlockingViolationTable.$scoped.withValue(table) { _ = sharedRead() }
        _ = await Task.detached { BlockingViolationTable.$scoped.withValue(table) { sharedRead() } }.value
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(Set(sites.map(\.context)) == [.main, .pool])
        #expect(Set(sites.map(\.location)).count == 1)
        BlockingDetector(table: table).resetCounts()
        #expect(BlockingDetector(table: table).sites.map(\.count) == [0, 0])
    }

    // MARK: bounds (the pool has its own table and ring, and its own overflow)

    /// 128 pool sites, then only counts: the 5 past the limit count in the pool's overflow, not the main
    /// thread's. Batches stay under the ring's 64, so the ring never decides the result.
    @Test func thePoolTableKeepsAtMostItsLimitAndCountsTheRest() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let recorder = PoolRecorder()
        BlockingDetector(table: table).install(sink: recorder)
        let extra = 5
        let lines = Array(0..<UInt(BlockingViolationTable.siteLimit + extra))
        for batch in stride(from: 0, to: lines.count, by: 32) {
            let batchLines = Array(lines[batch..<min(batch + 32, lines.count)])
            await onQueue(.global(qos: .utility)) {
                BlockingViolationTable.$scoped.withValue(table) {
                    for line in batchLines { assertBlockingAllowed(.fileIO, fileID: #fileID, line: line) }
                }
            }
            await table.flush()
        }

        let detector = BlockingDetector(table: table)
        #expect(detector.sites.count == BlockingViolationTable.siteLimit)
        #expect(detector.sites.allSatisfy { $0.context == .pool })
        #expect(detector.overflow(in: .pool) == extra)
        #expect(detector.overflow(in: .main) == 0)
        #expect(detector.overflow == extra)
        #expect(recorder.violations.count == BlockingViolationTable.siteLimit)
    }

    /// A new pool site that finds the pool ring full counts in the pool's overflow, and its next call, after the
    /// drain caught up, records it.
    @Test func aPoolSiteThatFindsTheRingFullIsRecordedOnItsNextCall() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record, startsDrain: false)
        let ringFull = UInt(BlockingViolationTable.pendingLimit)
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                for line in 0..<ringFull { assertBlockingAllowed(.fileIO, fileID: #fileID, line: line) }
                assertBlockingAllowed(.syncWait, fileID: #fileID, line: ringFull)  // the ring is full
            }
        }
        #expect(table.overflow(in: .pool) == 1)
        #expect(table.overflow(in: .main) == 0)
        table.startDrain()
        await table.flush()
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                assertBlockingAllowed(.syncWait, fileID: #fileID, line: ringFull)
            }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.count == Int(ringFull) + 1)
        #expect(sites.last?.kind == .syncWait)
        #expect(sites.last?.context == .pool)
    }

    #if DEBUG
    /// A pool violation keeps as many caller frames as a main one: both walk the stack in the frame that
    /// records the site, with no closure or lock frame above it, so the frames of the shared caller sit at the
    /// same depth in both (Debug, where nothing is inlined).
    @MainActor @Test func aPoolViolationKeepsTheCallerFramesAMainOneKeeps() async throws {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        let recorder = PoolRecorder()
        BlockingDetector(table: table).install(sink: recorder)
        BlockingViolationTable.$scoped.withValue(table) {
            for pool in [false, true] { recordFromOneCaller(pool: pool) }
        }
        await table.flush()

        let main = try #require(recorder.violations.first { $0.context == .main }).frames
        let pool = try #require(recorder.violations.first { $0.context == .pool }).frames
        let shared = main.filter(pool.contains)
        #expect(!shared.isEmpty)
        #expect(shared.allSatisfy { main.firstIndex(of: $0) == pool.firstIndex(of: $0) })
    }
    #endif

    // MARK: where blocking is allowed (acceptance: 0 sites)

    @Test func aSeamOnALaneRecordsNothing() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) { BlockingContext.run(as: .lane) { _ = checkedRead() } }
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    @Test func aSeamOnANamedSerialQueueRecordsNothingAndReadsNoClock() async {
        let clock = PoolStepClock(step: 1_000)
        let table = BlockingViolationTable(mode: .record, poolMode: .record, uptimeNanos: { clock.read() })
        await onQueue(DispatchQueue(label: "com.cmuxterm.tests.pool-context-serial")) {
            BlockingViolationTable.$scoped.withValue(table) { _ = checkedRead() }
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
        #expect(clock.reads == 0)
    }

    /// `allowBlocking` off the main thread marks the thread dedicated for its body (Chrome's
    /// `ScopedAllowBlocking` works on any thread).
    @Test func anAllowedSeamOnThePoolRecordsNothing() async {
        let table = BlockingViolationTable(mode: .record, poolMode: .record)
        await onQueue(.global(qos: .utility)) {
            BlockingViolationTable.$scoped.withValue(table) {
                allowBlocking(BlockingAllowance(reviewed: "test")) { _ = checkedRead() }
            }
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    // MARK: modes

    @Test func poolModeRecordsUnlessAskedToTrap() {
        #expect(BlockingViolationTable(environment: [:]).poolMode == .record)
        #expect(BlockingViolationTable(environment: ["CMUX_BLOCKING_TRAP": "1"]).poolMode == .record)
        #if DEBUG
        #expect(BlockingViolationTable(environment: ["CMUX_BLOCKING_TRAP_POOL": "1"]).poolMode == .trap)
        #expect(BlockingViolationTable(environment: ["CMUX_BLOCKING_TRAP_POOL": "1"]).mode == .record)
        #expect(BlockingDetector(table: BlockingViolationTable(poolMode: .trap)).poolMode == .trap)
        #else
        // A bench (and, to come, a Nightly) never stops the app, whatever it was asked.
        #expect(BlockingViolationTable(environment: ["CMUX_BLOCKING_TRAP_POOL": "1"]).poolMode == .record)
        #expect(BlockingViolationTable(poolMode: .trap).poolMode == .record)
        #endif
    }

    #if DEBUG
    @Test func aSeamOnThePoolTrapsInPoolTrapMode() async {
        await #expect(processExitsWith: .failure) {
            let table = BlockingViolationTable(mode: .record, poolMode: .trap)
            _ = await Task.detached { BlockingViolationTable.$scoped.withValue(table) { checkedRead() } }.value
        }
    }

    /// Main-thread trap mode does not stop a pool call: each context has its own switch.
    @Test func mainTrapModeDoesNotTrapThePool() async {
        await #expect(processExitsWith: .success) {
            let table = BlockingViolationTable(mode: .trap, poolMode: .record)
            _ = await Task.detached { BlockingViolationTable.$scoped.withValue(table) { checkedRead() } }.value
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

/// One checked file-existence call on the caller's thread; returns the line of the call (its site).
private nonisolated func checkedRead() -> UInt {
    let line: UInt = #line + 1
    _ = FileManager.checked.fileExists(atPath: "/etc/hosts")
    return line
}

#if DEBUG
/// Records one site in the main context or, called with `pool`, in the pool context, from one caller frame.
@inline(never)
private nonisolated func recordFromOneCaller(pool: Bool) {
    if pool {
        BlockingViolationTable.offMainBlocked(.fileIO, in: .pool, fileID: #fileID, line: 1)
    } else {
        BlockingViolationTable.mainThreadBlocked(.fileIO, fileID: #fileID, line: 1)
    }
}
#endif

/// One checked call at a single line, made from either thread.
private nonisolated func sharedRead() -> Bool {
    FileManager.checked.fileExists(atPath: "/etc/hosts")
}

/// A sink that keeps what it is given.
private nonisolated final class PoolRecorder: BlockingViolationSink, Sendable {
    private let seen = Mutex<[BlockingViolation]>([])
    var violations: [BlockingViolation] { seen.withLock { $0 } }

    func record(_ violation: BlockingViolation) {
        seen.withLock { $0.append(violation) }
    }
}

/// A clock that moves `step` nanoseconds per read, so each timed call (two reads) measures `step`.
private nonisolated final class PoolStepClock: Sendable {
    private let state = Mutex((reads: 0, now: UInt64(0)))
    private let step: UInt64

    init(step: UInt64) {
        self.step = step
    }

    var reads: Int { state.withLock { $0.reads } }

    func read() -> UInt64 {
        state.withLock { state in
            state.reads += 1
            state.now += step
            return state.now
        }
    }
}
#endif
