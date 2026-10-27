@testable import CmuxNextCompat
import Foundation
import Testing

/// The wall time `blockingCall` adds to a main-thread site (`debug.blocking`'s `total_ms` and `max_ms`). Each
/// test binds its own table (``BlockingViolationTable/scoped``) and, where the value matters, its own clock.
@Suite(.serialized)
struct BlockingWallTimeTests {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    /// A 5 ms sleep inside `blockingCall(.sleep)` on the main thread reports at least 5 ms as the site's maximum
    /// and total (the real clock).
    @MainActor @Test func aFiveMillisecondSleepOnTheMainThreadReportsItsWallTime() async {
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            blockingCall(.sleep) { _ = usleep(5_000) }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind) == [.sleep])
        #expect(sites.map(\.count) == [1])
        #expect(sites.first.map { $0.maxNanos >= 5_000_000 } == true)
        #expect(sites.first.map { $0.totalNanos >= $0.maxNanos } == true)
    }

    /// Each recorded call at a site adds its time to the site's total and keeps the longest as its maximum;
    /// two clock reads per call.
    @MainActor @Test func repeatedCallsAddToTheTotalAndKeepTheMaximum() async {
        let clock = StepClock(durations: [3_000_000, 7_000_000, 2_000_000])
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        BlockingViolationTable.$scoped.withValue(table) {
            for _ in 0..<3 { blockingCall(.fileIO) {} }  // one site
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.count) == [3])
        #expect(sites.map(\.totalNanos) == [12_000_000])
        #expect(sites.map(\.maxNanos) == [7_000_000])
        #expect(clock.reads == 6)
        BlockingDetector(table: table).resetCounts()
        #expect(BlockingDetector(table: table).sites.map { [$0.count, Int($0.totalNanos), Int($0.maxNanos)] } == [[0, 0, 0]])
    }

    /// Off the main thread, and on it inside an allowance, a blocking call is not a violation and reads no
    /// clock (the off-main path never reaches the table).
    @MainActor @Test func callsThatAreNotViolationsReadNoClock() async {
        let clock = StepClock(durations: [1_000_000])
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        await BlockingViolationTable.$scoped.withValue(table) { await blockingCallOffTheMainThread() }
        BlockingViolationTable.$scoped.withValue(table) {
            allowBlocking(BlockingAllowance(reviewed: "test")) { blockingCall(.fileIO) {} }
        }
        await table.flush()

        #expect(clock.reads == 0)
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// `blockingCall` returns its body's value and throws its body's typed error, recorded or not.
    @MainActor @Test func aBlockingCallPassesOnItsBodysValueAndTypedError() async {
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            #expect(blockingCall(.fileIO) { 42 } == 42)
            #expect(throws: BodyFailure.self) {
                _ = try blockingCall(.fileIO) { () throws(BodyFailure) -> Int in throw BodyFailure() }
            }
        }
        await table.flush()

        #expect(BlockingDetector(table: table).sites.map(\.count) == [1, 1])
    }

    // MARK: nesting (Chrome times only the outermost scope)

    /// Only the outermost timed call is timed (Chrome's `previous_scoped_blocking_call_` rule in
    /// base/threading/scoped_blocking_call_internal.cc): a call inside it counts at its own site without time,
    /// so the sites' total is the one interval, read with 2 clock reads.
    @MainActor @Test func aCallInsideATimedCallCountsWithoutTime() async {
        let clock = StepClock(durations: [5_000_000])
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        BlockingViolationTable.$scoped.withValue(table) {
            blockingCall(.syncWait) {
                blockingCall(.fileIO) {}  // its own line: a site is a file and line
            }
            blockingCall(.fileIO) {}  // outside: timed again
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.map(\.kind) == [.syncWait, .fileIO, .fileIO])
        #expect(sites.map(\.count) == [1, 1, 1])
        #expect(sites.map(\.totalNanos) == [5_000_000, 0, 5_000_000])
        #expect(clock.reads == 4)
    }

    /// `blockingSync` on the main thread runs its work on the caller's thread when it can; a checked call in
    /// that work is not timed a second time.
    @MainActor @Test func aSeamInsideBlockingSyncIsNotTimedTwice() async {
        let clock = StepClock(durations: [5_000_000])
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        let queue = DispatchQueue(label: "com.cmuxterm.tests.blocking-sync")
        BlockingViolationTable.$scoped.withValue(table) {
            _ = queue.blockingSync { FileManager.checked.fileExists(atPath: "/") }
        }
        await table.flush()

        let sites = BlockingDetector(table: table).sites
        #expect(sites.first?.kind == .syncWait)
        #expect(sites.reduce(0) { $0 + $1.totalNanos } == 5_000_000)
        #expect(clock.reads == 2)
    }

    #if canImport(Darwin)
    /// A timed call that runs the main run loop again (`waitUntilExit`, a modal panel, `RunLoop.run(until:)`)
    /// keeps the whole interval; a checked call the nested run makes counts at its site without time, so the
    /// interval is not counted twice. Alone in a child process (a nested run would run other tests' main-actor
    /// work). The calls name their lines: in an exit test's body every `#line` is the macro's line, so the two
    /// calls would be one site. Exit codes: 0 right; 3 wrong kinds; 4 wrong counts; 5 the outer call has no time;
    /// 6 the nested call has time.
    @Test func aCallInANestedRunLoopInsideATimedCallCountsWithoutTime() async {
        await #expect(processExitsWith: .exitCode(0)) {
            let table = BlockingViolationTable(mode: .record)
            await BlockingViolationTable.$scoped.withValue(table) {
                await MainActor.run {
                    blockingCall(.processWait, line: 1) {
                        // The nested run's work: a timer, a source, so the mode is not empty (a run of an empty
                        // mode returns at once); it ends the run.
                        RunLoop.main.add(Timer(timeInterval: 0, repeats: false) { _ in
                            _ = FileManager.checked.fileExists(atPath: "/", line: 2)
                            CFRunLoopStop(CFRunLoopGetMain())
                        }, forMode: .default)
                        _ = CFRunLoopRunInMode(.defaultMode, 5, false)
                    }
                }
            }
            await table.flush()
            let sites = BlockingDetector(table: table).sites
            guard sites.map(\.kind) == [.processWait, .fileIO] else { exit(3) }
            guard sites.map(\.count) == [1, 1] else { exit(4) }
            guard sites[0].totalNanos > 0 else { exit(5) }
            exit(sites[1].totalNanos == 0 ? 0 : 6)
        }
    }
    #endif

    // MARK: windows (reset)

    /// A reset while a timed call runs (`debug.blocking` with `reset` runs off the main thread) puts the whole
    /// call, its count and its time, in the next window: the call is counted when it ends, as Chrome's
    /// IOJankMonitoringWindow puts a call in the window it ends in.
    @MainActor @Test func aResetDuringACallPutsTheWholeCallInTheNextWindow() async {
        let clock = StepClock(durations: [3_000_000, 7_000_000])
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        let detector = BlockingDetector(table: table)
        BlockingViolationTable.$scoped.withValue(table) {
            for call in 0..<2 { blockingCall(.fileIO) { if call == 1 { detector.resetCounts() } } }  // one site
        }
        await table.flush()

        #expect(detector.sites.map { [$0.count, Int($0.totalNanos), Int($0.maxNanos)] } == [[1, 7_000_000, 7_000_000]])
    }

    // MARK: every seam is timed

    /// Every seam runs its primitive through `blockingCall`: on the main thread each records one site at its
    /// caller's line with the injected clock's step as its time. (`Process.blockingWaitUntilExit` runs the main
    /// run loop, which would run other tests' main-actor work, so it is left out (its routing is the one line in
    /// Process+Blocking.swift); the XPC seam needs a service. The system-call
    /// seams are in BlockingSystemSeamTests.)
    @MainActor @Test func eachSeamOnTheMainThreadAddsItsWallTime() async throws {
        let step: UInt64 = 4_000_000
        let clock = StepClock(durations: [step])
        let table = BlockingViolationTable(mode: .record, uptimeNanos: { clock.read() })
        let expected = try BlockingViolationTable.$scoped.withValue(table) { try callEachSeam(step: step) }
        await table.flush()

        #expect(expected.count == 21)
        #expect(Set(expected.map(\.location)).count == expected.count)
        #expect(BlockingDetector(table: table).sites == expected)
    }
    #endif
}

#if DEBUG || CMUX_BLOCKING_CHECKS
/// Calls every seam once on the caller's thread and returns the site each call records on the main thread:
/// its kind, this file's line of the call, a count of 1 and `step` as its time.
private nonisolated func callEachSeam(step: UInt64) throws -> [BlockingSite] {
    var expected: [BlockingSite] = []
    func seam(_ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line, _ call: () throws -> Void) rethrows {
        expected.append(BlockingSite(kind: kind, location: "\(fileID):\(line)", count: 1, totalNanos: step, maxNanos: step))
        try call()
    }

    let hosts = URL(fileURLWithPath: "/etc/hosts")
    let devNull = URL(fileURLWithPath: "/dev/null")
    seam(.fileIO) { _ = try? Data(blockingContentsOf: hosts) }
    seam(.fileIO) { _ = try? Data([1]).blockingWrite(to: devNull) }
    seam(.fileIO) { _ = try? String(blockingContentsOf: hosts, encoding: .utf8) }
    seam(.fileIO) { _ = try? String(blockingContentsOf: hosts) }
    seam(.fileIO) { _ = try? String(blockingContentsOfFile: hosts.path, encoding: .utf8) }
    seam(.fileIO) { _ = try? "x".blockingWrite(to: devNull, atomically: false, encoding: .utf8) }
    seam(.fileIO) { _ = FileManager.checked.fileExists(atPath: hosts.path) }
    let reader = try #require(FileHandle(forReadingAtPath: hosts.path))
    seam(.fileIO) { _ = try? reader.blockingReadToEnd() }
    seam(.fileIO) { FileHandle.nullDevice.blockingWrite(Data([1])) }
    seam(.fileIO) { _ = try? hosts.blockingResourceValues(forKeys: [.fileSizeKey]) }

    let semaphore = DispatchSemaphore(value: 0)
    semaphore.signal()
    seam(.syncWait) { _ = semaphore.blockingWait(timeout: .now()) }
    seam(.syncWait) { _ = DispatchGroup().blockingWait(timeout: .now()) }
    let item = DispatchWorkItem {}
    item.perform()
    seam(.syncWait) { item.blockingWait() }
    let queue = DispatchQueue(label: "com.cmuxterm.tests.blocking-wall-time")
    seam(.syncWait) { _ = queue.blockingSync { 1 } }
    let condition = NSCondition()
    condition.lock()
    seam(.syncWait) { _ = condition.blockingWait(until: Date()) }
    condition.unlock()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try seam(.processSpawn) { try process.blockingRun() }
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
    defer { argv.forEach { free($0) } }
    seam(.processSpawn) { _ = blockingPosixSpawn(&pid, "/usr/bin/true", nil, nil, argv, environ) }
    var status: Int32 = 0
    if pid > 0 { waitpid(pid, &status, 0) }

    let descriptor = open("/dev/null", O_RDWR)
    defer { close(descriptor) }
    var byte: UInt8 = 0
    seam(.socketRead) { _ = blockingRead(descriptor, &byte, 1) }
    seam(.socketRead) { _ = blockingRecv(descriptor, &byte, 1, 0) }  // not a socket: fails at once, still timed
    seam(.socketWrite) { _ = blockingWrite(descriptor, &byte, 1) }
    seam(.socketWrite) { _ = blockingSend(descriptor, &byte, 1, 0) }
    return expected
}

/// A seam on a named serial queue (blocking is allowed there; the pool is BlockingPoolContextTests'), with the
/// caller's table bound there.
private nonisolated func blockingCallOffTheMainThread() async {
    let table = BlockingViolationTable.scoped
    let queue = DispatchQueue(label: "com.cmuxterm.tests.blocking-wall-time-off-main")
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        queue.async {
            BlockingViolationTable.$scoped.withValue(table) { _ = FileManager.checked.fileExists(atPath: "/etc/hosts") }
            done.resume()
        }
    }
}

/// A clock for timed blocking calls: each timed call reads it twice (start, end), and timed call `n` measures
/// `durations[n % durations.count]`.
private nonisolated final class StepClock: Sendable {
    private let state = Mutex((reads: 0, now: UInt64(1_000)))
    private let durations: [UInt64]

    init(durations: [UInt64]) {
        self.durations = durations
    }

    var reads: Int { state.withLock { $0.reads } }

    func read() -> UInt64 {
        state.withLock { state in
            defer { state.reads += 1 }
            if state.reads % 2 == 1 { state.now += durations[(state.reads / 2) % durations.count] }
            return state.now
        }
    }
}

/// The typed error a blocking call's body throws.
private nonisolated struct BodyFailure: Error {}
#endif
