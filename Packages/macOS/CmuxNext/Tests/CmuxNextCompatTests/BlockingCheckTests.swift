@testable import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The main-thread blocking detector (plans/cmux-next/threading-model.md). Each test binds its own
/// table (``BlockingViolationTable/scoped``), so suites that run beside it cannot change what it
/// sees. Trap cases run in a child process (exit tests).
@Suite(.serialized)
struct BlockingCheckTests {
    #if DEBUG
    // MARK: trap mode (Debug: CMUX_BLOCKING_TRAP=1, and these tests)

    @Test func aFileReadOnTheMainThreadTraps() async {
        await #expect(processExitsWith: .failure) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await MainActor.run { _ = try? Data(blockingContentsOf: URL(fileURLWithPath: "/etc/hosts")) }
            }
        }
    }

    @Test func aCheckedFileManagerCallOnTheMainThreadTraps() async {
        await #expect(processExitsWith: .failure) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await MainActor.run { _ = FileManager.checked.fileExists(atPath: "/etc/hosts") }
            }
        }
    }

    @Test func aSemaphoreWaitOnTheMainThreadTraps() async {
        await #expect(processExitsWith: .failure) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await MainActor.run { signaledSemaphore().blockingWait() }
            }
        }
    }

    @Test func aProcessWaitOnTheMainThreadTraps() async {
        await #expect(processExitsWith: .failure) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await MainActor.run {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                    try? process.run()
                    process.blockingWaitUntilExit()
                }
            }
        }
    }

    /// A long lock wait is measured on the wall clock (it includes scheduling): even trap mode only
    /// records it.
    @Test func aLongLockWaitNeverTraps() async {
        await #expect(processExitsWith: .success) {
            let fixture = await BlockingCheckTests.lockTable(measuredNanos: BlockingKind.lockWaitLimitNanos * 10, mode: .trap)
            await BlockingCheckTests.waitForAHeldMutex(fixture) { $0.mutex.withLock { $0 += 1 } }
            #expect(BlockingDetector(table: fixture.table).sites.map(\.kind) == [.lockWait])
        }
    }

    /// A process started from main-actor code stops a Debug build in trap mode (the 807 ms screen.close
    /// stall of 2026-10-24 was a spawn on the main thread).
    @Test func aProcessSpawnOnTheMainThreadTraps() async {
        await #expect(processExitsWith: .failure) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await MainActor.run { try? spawnTrue() }
            }
        }
    }

    @Test func theTrapEnvironmentVariableTurnsTrapModeOn() async {
        await #expect(processExitsWith: .failure) {
            let table = BlockingViolationTable(environment: ["CMUX_BLOCKING_TRAP": "1"])
            await BlockingViolationTable.$scoped.withValue(table) {
                await MainActor.run { _ = FileManager.checked.fileExists(atPath: "/") }
            }
        }
    }

    @Test func withoutTheVariableADebugBuildRecords() {
        #expect(BlockingViolationTable(environment: [:]).mode == .record)
    }

    @Test func theSameCallsOffTheMainThreadDoNotTrap() async {
        await #expect(processExitsWith: .success) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await blockingCallsOffTheMainThread()
            }
        }
    }

    @Test func anAllowedCallOnTheMainThreadDoesNotTrap() async {
        await #expect(processExitsWith: .success) {
            await BlockingViolationTable.$scoped.withValue(BlockingViolationTable(mode: .trap)) {
                await MainActor.run {
                    allowBlocking(BlockingAllowance(reviewed: "test")) {
                        _ = try? Data(blockingContentsOf: URL(fileURLWithPath: "/etc/hosts"))
                        _ = FileManager.checked.fileExists(atPath: "/etc/hosts")
                    }
                }
            }
        }
    }
    #elseif CMUX_BLOCKING_CHECKS
    // MARK: Nightly (Release + CMUX_BLOCKING_CHECKS): records, never traps

    @Test func aNightlyNeverTrapsEvenWhenAskedTo() async {
        await #expect(processExitsWith: .success) {
            let table = BlockingViolationTable(environment: ["CMUX_BLOCKING_TRAP": "1"], mode: .trap)
            await BlockingViolationTable.$scoped.withValue(table) {
                await MainActor.run { _ = FileManager.checked.fileExists(atPath: "/") }
            }
        }
    }
    #endif

    #if DEBUG || CMUX_BLOCKING_CHECKS
    // MARK: record mode (Nightly, and Debug by default)

    @MainActor @Test func recordModeRecordsEachCallSiteOnceAndCountsRepeats() async {
        let (table, recorder) = Self.recordingTable()
        await BlockingViolationTable.$scoped.withValue(table) {
            for _ in 0..<3 { _ = try? Data(blockingContentsOf: URL(fileURLWithPath: "/etc/hosts")) }  // one site
            _ = FileManager.checked.fileExists(atPath: "/etc/hosts")
            _ = signaledSemaphore().blockingWait(timeout: .now())
            let descriptor = open("/dev/null", O_RDONLY)
            var byte: UInt8 = 0
            _ = blockingRead(descriptor, &byte, 1)
            close(descriptor)
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind) == [.fileIO, .fileIO, .syncWait, .socketRead])
        #expect(sites.map(\.count) == [3, 1, 1, 1])
        #expect(sites.allSatisfy { $0.location.hasPrefix("CmuxNextCompatTests/BlockingCheckTests.swift:") })
        #expect(recorder.violations.map(\.kind) == [.fileIO, .fileIO, .syncWait, .socketRead])
        #expect(recorder.violations.allSatisfy { !$0.frames.isEmpty && $0.frames.count <= 8 })
    }

    /// A main-actor caller that starts a process is recorded, by either spawn seam; the same spawn off the
    /// main thread is not.
    @MainActor @Test func aProcessSpawnFromMainActorCodeIsRecorded() async throws {
        let (table, recorder) = Self.recordingTable()
        try BlockingViolationTable.$scoped.withValue(table) {
            try spawnTrue()
            try posixSpawnTrue()
        }
        try await BlockingViolationTable.$scoped.withValue(table) { try await spawnTrueOffMain() }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.map(\.kind) == [.processSpawn, .processSpawn])
        #expect(recorder.violations.count == 2)
    }

    /// 128 sites, then only counts: the 5 sites past the limit are never recorded. Batches stay under the
    /// ring's 64, so the ring never decides the result.
    @MainActor @Test func theTableKeepsAtMostItsLimitAndCountsTheRest() async {
        let (table, recorder) = Self.recordingTable()
        let extra = 5
        let lines = Array(0..<UInt(BlockingViolationTable.siteLimit + extra))
        for batch in stride(from: 0, to: lines.count, by: 32) {
            BlockingViolationTable.$scoped.withValue(table) {
                for line in lines[batch..<min(batch + 32, lines.count)] {
                    assertBlockingAllowed(.fileIO, fileID: #fileID, line: line)  // a distinct call site each
                }
            }
            await table.flush()
        }

        let detector = BlockingDetector(table: table)
        #expect(detector.sites.count == BlockingViolationTable.siteLimit)
        #expect(detector.overflow == extra)
        #expect(recorder.violations.count == BlockingViolationTable.siteLimit)
    }

    /// A new site that finds the ring full is not lost for the launch: it counts in `overflow`, and its next
    /// call, after the drain caught up, records it.
    @MainActor @Test func aSiteThatFindsTheRingFullIsRecordedOnItsNextCall() async {
        let table = BlockingViolationTable(mode: .record, startsDrain: false)
        let ringFull = UInt(BlockingViolationTable.pendingLimit)
        BlockingViolationTable.$scoped.withValue(table) {
            for line in 0..<ringFull { assertBlockingAllowed(.fileIO, fileID: #fileID, line: line) }
            assertBlockingAllowed(.syncWait, fileID: #fileID, line: ringFull)  // the ring is full
        }
        #expect(table.overflow == 1)
        table.startDrain()
        await table.flush()
        BlockingViolationTable.$scoped.withValue(table) {
            assertBlockingAllowed(.syncWait, fileID: #fileID, line: ringFull)
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.count == Int(ringFull) + 1)
        #expect(sites.last?.kind == .syncWait)
    }

    @MainActor @Test func theAllowScopeEndsWithItsBody() async {
        let (table, recorder) = Self.recordingTable()
        await BlockingViolationTable.$scoped.withValue(table) {
            allowBlocking(BlockingAllowance(reviewed: "test")) { _ = FileManager.checked.fileExists(atPath: "/") }
            _ = FileManager.checked.fileExists(atPath: "/")
        }
        await table.flush()

        #expect(recorder.violations.count == 1)
    }

    /// `waitUntilExit` runs the main run loop while it waits; the work that loop runs is not the allowed
    /// wait, so it is still checked. A nested run of the main run loop would also run other tests' main-actor
    /// work in this process, so the case runs alone in a child process and reports through its exit code.
    @Test func aProcessWaitDoesNotLendItsAllowanceToTheRunLoop() async {
        await #expect(processExitsWith: .exitCode(0)) {
            let table = BlockingViolationTable(mode: .record)
            try? await BlockingViolationTable.$scoped.withValue(table) {
                try await MainActor.run {
                    let input = Pipe()
                    let writer = input.fileHandleForWriting
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/cat")
                    process.standardInput = input
                    process.standardOutput = FileHandle.nullDevice
                    try process.run()
                    // Runs inside the wait below; closing cat's input ends cat, which ends the wait.
                    RunLoop.main.perform {
                        _ = FileManager.checked.fileExists(atPath: "/")
                        try? writer.close()
                    }
                    allowBlocking(BlockingAllowance(reviewed: "test")) { process.blockingWaitUntilExit() }
                }
            }
            await table.flush()
            exit(BlockingDetector(table: table).sites.map(\.kind) == [.fileIO] ? 0 : 3)
        }
    }

    /// Any nested run of the main run loop holds the allowance back while it runs, not only a process wait.
    /// Alone in a child process, for the reason above.
    @Test func aNestedRunLoopDoesNotShareTheAllowance() async {
        await #expect(processExitsWith: .exitCode(0)) {
            let table = BlockingViolationTable(mode: .record)
            await BlockingViolationTable.$scoped.withValue(table) {
                await MainActor.run {
                    allowBlocking(BlockingAllowance(reviewed: "test")) {
                        RunLoop.main.perform { _ = FileManager.checked.fileExists(atPath: "/") }  // the nested run's work
                        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
                        _ = FileManager.checked.fileExists(atPath: "/")  // the body again: allowed
                    }
                }
            }
            await table.flush()
            exit(BlockingDetector(table: table).sites.map(\.kind) == [.fileIO] ? 0 : 3)
        }
    }

    /// A nested run of the main run loop in the event-tracking mode (as menu tracking, a drag session or a
    /// modal panel runs it) that runs ANOTHER main-actor job, which itself opens and closes an allowance and
    /// makes a checked call, while the outer allowance is open: no trap, the nested job's unallowed call is
    /// recorded, its allowed call is not, and the outer allowance is back after the nested run. One table for
    /// both jobs, as in the app.
    @Test func aNestedTrackingRunThatRunsAnotherMainActorJobRecordsItAndDoesNotTrap() async {
        await #expect(processExitsWith: .exitCode(0)) {
            let table = BlockingViolationTable(mode: .record)
            let ranNested = await BlockingViolationTable.$scoped.withValue(table) {
                await MainActor.run { () -> Bool in
                    // AppKit adds its event-tracking mode to the common modes; this process has no
                    // NSApplication, so add it the same way.
                    let tracking = CFRunLoopMode(rawValue: "NSEventTrackingRunLoopMode" as CFString)
                    CFRunLoopAddCommonMode(CFRunLoopGetMain(), tracking)
                    let ran = SharedCount()  // Sendable: the run-loop block below is a @Sendable closure
                    allowBlocking(BlockingAllowance(reviewed: "test")) {
                        // Another main-thread job, delivered by the nested tracking run as AppKit delivers
                        // events and timers there (a run-loop block in that mode). It opens its own allowance,
                        // then makes one call outside it.
                        RunLoop.main.perform(inModes: [RunLoop.Mode(tracking.rawValue as String)]) {
                            allowBlocking(BlockingAllowance(reviewed: "test-inner")) {
                                _ = FileManager.checked.fileExists(atPath: "/")  // allowed by the inner scope
                            }
                            _ = FileManager.checked.isReadableFile(atPath: "/")  // not allowed: recorded
                            ran.mutex.withLock { $0 = 1 }
                        }
                        // Bounded: the block is already queued; each run returns after handling one source.
                        for _ in 0..<100 where ran.mutex.withLock({ $0 }) == 0 { _ = CFRunLoopRunInMode(tracking, 1, true) }
                        _ = FileManager.checked.isWritableFile(atPath: "/")  // the outer body again: allowed
                    }
                    return ran.mutex.withLock { $0 } == 1
                }
            }
            await table.flush()
            let sites = BlockingDetector(table: table).sites
            // 0: right; 3: the nested job did not run; 4: wrong sites recorded.
            exit(!ranNested ? 3 : sites.count == 1 && sites.first?.kind == .fileIO && sites.first?.count == 1 ? 0 : 4)
        }
    }

    @MainActor @Test func offTheMainThreadNothingIsRecorded() async {
        let (table, recorder) = Self.recordingTable()
        await BlockingViolationTable.$scoped.withValue(table) {
            await blockingCallsOffTheMainThread()
        }
        await table.flush()

        #expect(recorder.violations.isEmpty)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    @MainActor @Test func aContendedMutexWaitPastTheLimitIsRecorded() async {
        let fixture = Self.lockTable(measuredNanos: BlockingKind.lockWaitLimitNanos + 1)
        await Self.waitForAHeldMutex(fixture) { $0.mutex.withLock { $0 += 1 } }
        #expect(BlockingDetector(table: fixture.table).sites.map(\.kind) == [.lockWait])
    }

    @MainActor @Test func aContendedMutexWaitUnderTheLimitIsNot() async {
        let fixture = Self.lockTable(measuredNanos: BlockingKind.lockWaitLimitNanos - 1)
        await Self.waitForAHeldMutex(fixture) { $0.mutex.withLock { $0 += 1 } }
        #expect(BlockingDetector(table: fixture.table).sites.isEmpty)
        #expect(fixture.clock.reads == 2)  // the wait was contended and timed
    }

    /// Each `withLock` call is its own site (the caller's #fileID and #line), as for the seams.
    @MainActor @Test func twoMutexCallSitesAreTwoSites() async {
        let fixture = Self.lockTable(measuredNanos: BlockingKind.lockWaitLimitNanos + 1)
        await Self.waitForAHeldMutex(fixture) { $0.mutex.withLock { $0 += 1 } }
        await Self.waitForAHeldMutex(fixture) { $0.mutex.withLock { $0 += 2 } }
        await Self.waitForAHeldMutex(fixture) { $0.mutex.withLock { $0 += 1 } }

        let sites = BlockingDetector(table: fixture.table).sites
        #expect(sites.count == 3)
        #expect(Set(sites.map(\.location)).count == 3)
        #expect(sites.allSatisfy { $0.location.hasPrefix("CmuxNextCompatTests/BlockingCheckTests.swift:") })
    }

    @MainActor @Test func anUncontendedMutexIsNeverTimed() async {
        let clock = FakeClock(step: BlockingKind.lockWaitLimitNanos * 10)
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        await BlockingViolationTable.$scoped.withValue(table) {
            let shared = SharedCount()
            shared.mutex.withLock { $0 += 1 }
        }
        await table.flush()

        #expect(clock.reads == 0)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// The sink runs on the drain queue, never inside the blocked thread's locks: a sink that
    /// takes a lock the blocking caller holds must not stop the process (os_unfair_lock traps on
    /// a recursive take).
    @MainActor @Test func aSinkMayTakeALockTheBlockingCallerHolds() async {
        let gate = SharedCount()
        let sink = LockingSink(gate: gate)
        let table = BlockingViolationTable(mode: .record)
        BlockingDetector(table: table).install(sink: sink)
        await BlockingViolationTable.$scoped.withValue(table) {
            gate.mutex.withLock { _ in _ = FileManager.checked.fileExists(atPath: "/") }
        }
        await table.flush()

        #expect(sink.recorded == 1)
    }

    /// A sink that itself blocks and reads the detector (it runs off the main thread) is fine.
    @MainActor @Test func aSinkMayBlockAndReadTheDetector() async {
        let table = BlockingViolationTable(mode: .record)
        let sink = ReentrantSink(detector: BlockingDetector(table: table))
        BlockingDetector(table: table).install(sink: sink)
        await BlockingViolationTable.$scoped.withValue(table) {
            _ = FileManager.checked.fileExists(atPath: "/")
        }
        await table.flush()

        #expect(sink.seenSites == [1])
        #expect(BlockingDetector(table: table).sites.count == 1)
    }

    // MARK: helpers

    private static func recordingTable() -> (BlockingViolationTable, Recorder) {
        let table = BlockingViolationTable(mode: .record)
        let recorder = Recorder()
        BlockingDetector(table: table).install(sink: recorder)
        return (table, recorder)
    }

    /// A table whose lock clock measures every contended wait as `measuredNanos` and, on the read at the
    /// start of each wait, lets the holder go: the main thread really waits, and no real time decides.
    private static func lockTable(measuredNanos: UInt64, mode: BlockingMode = .record) -> LockFixture {
        let clock = FakeClock(step: measuredNanos)
        return LockFixture(table: BlockingViolationTable(mode: mode, uptimeNanos: { clock.read() }), clock: clock)
    }

    /// Main runs `lock` (a `withLock` at the caller's line) while another thread holds the mutex, then
    /// waits for the drain.
    @MainActor
    private static func waitForAHeldMutex(_ fixture: LockFixture, _ lock: (SharedCount) -> Void) async {
        let shared = SharedCount()
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        fixture.clock.arm(release)
        Thread {
            shared.mutex.withLock { _ in
                held.signal()
                // Bounded: a regression that never arms the release fails the test instead of deadlocking it.
                _ = release.wait(timeout: .now() + .seconds(5))
            }
        }.start()
        waitUntilSignaled(held)  // the holder has the lock
        BlockingViolationTable.$scoped.withValue(fixture.table) { lock(shared) }
        await fixture.table.flush()
    }
    #else
    // MARK: Release: compiled out

    @MainActor @Test func releaseBuildsCheckNothing() {
        _ = try? Data(blockingContentsOf: URL(fileURLWithPath: "/etc/hosts"))
        _ = FileManager.checked.fileExists(atPath: "/")
        #expect(!BlockingDetector.forProcess().isCompiledIn)
        #expect(BlockingDetector.forProcess().sites.isEmpty)
    }
    #endif
}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// A semaphore made with value 0 and signaled once: one wait returns at once and leaves it at its initial
/// value. (A semaphore made with value 1 and waited on is below its initial value when it is released, and
/// libdispatch traps on that: the SIGTRAP of the suite runs at 1b71848e3c4 and ee33c68f2a3.)
private nonisolated func signaledSemaphore() -> DispatchSemaphore {
    let semaphore = DispatchSemaphore(value: 0)
    semaphore.signal()
    return semaphore
}

/// Waits for `semaphore` (a fixture step: the other thread signals it at once); synchronous, because
/// `DispatchSemaphore.wait()` is unavailable in async code.
private nonisolated func waitUntilSignaled(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

/// The seams on a thread of the global executor: off the main thread, in the caller's task (so its
/// task-local table applies, unlike a detached task).
@concurrent nonisolated
private func blockingCallsOffTheMainThread() async {
    #expect(pthread_main_np() == 0)
    _ = try? Data(blockingContentsOf: URL(fileURLWithPath: "/etc/hosts"))
    _ = FileManager.checked.fileExists(atPath: "/etc/hosts")
    signaledSemaphore().blockingWait()
}

/// Starts `/usr/bin/true` through the `Process` spawn seam, from the caller's thread.
private nonisolated func spawnTrue() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.blockingRun()
}

/// Starts `/usr/bin/true` through the `posix_spawn` seam and reaps it.
private nonisolated func posixSpawnTrue() throws {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
    defer { argv.forEach { free($0) } }
    let status = blockingPosixSpawn(&pid, "/usr/bin/true", nil, nil, argv, environ)
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    var exit: Int32 = 0
    waitpid(pid, &exit, 0)
}

/// The same spawn on a thread of the global executor, in the caller's task (its task-local table applies).
@concurrent
private nonisolated func spawnTrueOffMain() async throws {
    #expect(pthread_main_np() == 0)
    try spawnTrue()
}

/// A mutex threads can share (a `Mutex` is not copyable, so a closure cannot capture it).
private nonisolated final class SharedCount: Sendable {
    let mutex = Mutex(0)
}

/// A lock clock: each contended wait reads it twice (start, end) and measures `step`; the start read
/// signals the semaphore ``arm(_:)`` set, which lets the thread holding the mutex go.
private nonisolated final class FakeClock: Sendable {
    private let state = Mutex((reads: 0, release: DispatchSemaphore?.none))
    private let step: UInt64

    init(step: UInt64) {
        self.step = step
    }

    var reads: Int { state.withLock { $0.reads } }

    /// The holder of the next wait waits on `release`.
    func arm(_ release: DispatchSemaphore) {
        state.withLock { $0.release = release }
    }

    func read() -> UInt64 {
        let (index, release) = state.withLock { state -> (Int, DispatchSemaphore?) in
            defer { state.reads += 1 }
            let start = state.reads % 2 == 0
            let release = start ? state.release : nil
            if start { state.release = nil }
            return (state.reads, release)
        }
        release?.signal()
        return UInt64(index / 2) * 3 * step + UInt64(index % 2) * step
    }
}

/// A table and the clock its contended `Mutex` waits are measured with.
private nonisolated struct LockFixture: Sendable {
    let table: BlockingViolationTable
    let clock: FakeClock
}

/// Collects what the detector hands its sink.
private nonisolated final class Recorder: BlockingViolationSink {
    private let seen = Mutex<[BlockingViolation]>([])

    var violations: [BlockingViolation] { seen.withLock { $0 } }

    func record(_ violation: BlockingViolation) {
        seen.withLock { $0.append(violation) }
    }
}

/// A sink that takes `gate`, the lock the blocking caller held.
private nonisolated final class LockingSink: BlockingViolationSink {
    private let gate: SharedCount

    init(gate: SharedCount) {
        self.gate = gate
    }

    var recorded: Int { gate.mutex.withLock { $0 } }

    func record(_ violation: BlockingViolation) {
        gate.mutex.withLock { $0 += 1 }
    }
}

/// A sink that blocks (a file read) and reads the detector's sites while it records.
private nonisolated final class ReentrantSink: BlockingViolationSink {
    private let detector: BlockingDetector
    private let seen = Mutex<[Int]>([])

    init(detector: BlockingDetector) {
        self.detector = detector
    }

    var seenSites: [Int] { seen.withLock { $0 } }

    func record(_ violation: BlockingViolation) {
        _ = FileManager.checked.fileExists(atPath: "/")
        let count = detector.sites.count
        seen.withLock { $0.append(count) }
    }
}
#endif
