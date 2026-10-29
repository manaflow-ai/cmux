@testable import CmuxNextLaunch
import CmuxNextCompat
import CmuxNextTrace
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Dispatch
import Foundation
import os
import Testing

/// The startup trace (`CMUX_TRACE_STARTUP`, p08-startup task 004): the environment's one read, the ring, and
/// the Chrome Trace Event JSON file, whole and cut short.
@Suite struct StartupTraceTests {
    // MARK: configuration

    @Test func unsetReadsOneVariableAndBuildsNothing() {
        var reads: [String] = []
        var homeRead = false
        let configuration = StartupTraceConfiguration.fromEnvironment({ reads.append($0); return nil },
                                                                      home: { homeRead = true; return URL(fileURLWithPath: "/h") }(),
                                                                      pid: 7)
        #expect(configuration == nil)
        #expect(reads == [StartupTraceConfiguration.environmentKey])
        #expect(!homeRead)
    }

    @Test func zeroIsOffAndEmptyIsTheDefault() throws {
        #expect(Self.configuration(["CMUX_TRACE_STARTUP": "0"]) == nil)
        #expect(Self.configuration(["CMUX_TRACE_STARTUP": "-2"]) == nil)
        let empty = try #require(Self.configuration(["CMUX_TRACE_STARTUP": ""]))
        #expect(empty.seconds == StartupTraceConfiguration.defaultSeconds)
        #expect(empty.file.path == "/h/Library/Logs/cmux/startup-7.json")
        #expect(empty.chunkBytes == 64 * 1_024)
    }

    @Test func secondsAndFileComeFromTheVariableOrTheFileVariable() throws {
        let both = try #require(Self.configuration(["CMUX_TRACE_STARTUP": "12,/tmp/launch.json"]))
        #expect(both.seconds == 12)
        #expect(both.file.path == "/tmp/launch.json")
        let separate = try #require(Self.configuration(["CMUX_TRACE_STARTUP": "3",
                                                        "CMUX_TRACE_STARTUP_FILE": "/tmp/other.json"]))
        #expect(separate.seconds == 3)
        #expect(separate.file.path == "/tmp/other.json")
        let long = try #require(Self.configuration(["CMUX_TRACE_STARTUP": "100000"]))
        #expect(long.seconds == StartupTraceConfiguration.maximumSeconds)
    }

    /// Only an empty value or a positive number of seconds turns tracing on: `false`, `off` and the like
    /// (inherited by every shell the app starts) never write a trace file.
    @Test(arguments: ["false", "off", "no", "5s", "nan", "false,/tmp/launch.json"])
    func aValueThatIsNotANumberIsOff(value: String) {
        #expect(Self.configuration(["CMUX_TRACE_STARTUP": value]) == nil)
    }

    // MARK: ring

    @Test func aFullRingDropsAndCounts() {
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: Self.temporaryFile(), capacity: 4),
                                 processStartNanos: 0, clock: ManualClock(), now: { 10 })
        for index in 0..<6 { trace.mark("m\(index)") }
        let status = trace.status
        #expect(status.pending == 4)
        #expect(status.dropped == 2)
        #expect(status.ringBytes == 2 * 4 * MemoryLayout<StartupTraceRecord>.stride)
        #expect(!status.closed)
    }

    /// Each launch mark once; with a trace attached, a process_start mark and every later first mark reach it.
    @Test func launchMarksRecordEachNameOnceAndForwardToTheTrace() {
        let start = LaunchClock.Instant(wallNanos: UInt64((Date().timeIntervalSince1970 - 1) * 1e9), uptimeNanos: 5_000_000_000)
        let processStart = Date(timeIntervalSince1970: Double(start.wallNanos) / 1e9)
        var marks = LaunchMarks()
        let early = marks.record("early", at: Date(), processStart: processStart)
        #expect(early.map { $0 >= 1_000 } == true)
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: Self.temporaryFile()), processStartNanos: 0,
                                 clock: ManualClock())
        marks.attach(trace, processStart: start)
        #expect(marks.trace === trace)
        let now = Date()
        #expect(marks.record("main_start", at: now, processStart: processStart) != nil)
        LaunchMarks.forward("main_start", at: now, to: marks.trace, pairedWith: start)
        #expect(marks.record("main_start", at: Date(), processStart: processStart) == nil)
        #expect(marks.all.map { $0.name } == ["early", "main_start"])
        #expect(trace.status.pending == 2)
    }

    /// Every mark reaches the trace clock through the launch's one pairing (the process start, read once, as
    /// Chrome's `StartupTimeToTimeTicks` keeps one `time_base` and `trace_ticks_base`): a wall-clock step
    /// between two marks moves neither, while a pairing read again after the step would.
    @Test func aWallClockStepBetweenMarksMovesNoMark() throws {
        let second: UInt64 = 1_000_000_000
        let wall = WallClock(1_002 * second)
        let clock = LaunchClock(reader: LaunchClock.Reader(
            processStartWallNanos: { 1_000 * second }, wallNanos: { wall.nanos }, uptimeNanos: { 50 * second },
            pageins: { nil }))
        let pairing = try #require(clock.processStart())
        #expect(pairing == LaunchClock.Instant(wallNanos: 1_000 * second, uptimeNanos: 48 * second))

        let first = Date(timeIntervalSince1970: 1_001)
        #expect(LaunchMarks.uptimeNanos(of: first, pairedWith: pairing) == 49 * second)
        wall.set(2_000 * second) // the wall clock is set 998 s forward
        #expect(LaunchMarks.uptimeNanos(of: first, pairedWith: pairing) == 49 * second)
        #expect(LaunchMarks.uptimeNanos(of: Date(timeIntervalSince1970: 1_003), pairedWith: pairing) == 51 * second)
        #expect(LaunchMarks.uptimeNanos(of: first, pairedWith: clock.now()) != 49 * second,
                "a pairing read after the step moves the mark")

        #expect(LaunchMarks.uptimeNanos(of: Date(timeIntervalSince1970: 999), pairedWith: pairing) == 47 * second)
        #expect(LaunchMarks.uptimeNanos(of: Date(timeIntervalSince1970: 900), pairedWith: pairing) == 0)
    }

    // MARK: file

    /// Every kind of record, closed: the file is one JSON array that ends in `]`, with times in microseconds.
    @Test func aClosedTraceIsAFullChromeTraceFile() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: file), processStartNanos: 1_000,
                                 clock: ManualClock(), now: { 9_000_000 })
        // One slot per priority: the empty item below runs between the start's drain and the close's.
        let work = BackgroundWork(filesWidths: .serial, label: "test.startup-trace", onRan: trace.laneJobSink)
        trace.start(writingOn: work)
        trace.mark("main_start", at: 2_500)
        trace.mark("daemon.connect_start", at: 3_000)
        trace.task("startup.theme", start: 4_000, end: 6_500)
        trace.mainTurn(start: 7_000, end: 2_007_000)
        // Ahead of the close's drain on the one user-visible slot, so its record is in the ring by then.
        work.post(.userVisible, mayBlock: .files) {}
        trace.close()
        let closed = await Self.waitUntilClosed(trace)
        #expect(closed.closed)
        #expect(closed.failure == nil)

        let text = try Self.read(file)
        #expect(text.hasSuffix("]\n"))
        let events = try Self.parse(text)
        let mark = try #require(events.first { $0["name"] as? String == "main_start" })
        #expect(mark["ph"] as? String == "i")
        #expect(mark["cat"] as? String == "launch")
        #expect(mark["ts"] as? Double == 2.5)
        #expect(events.first { $0["name"] as? String == "daemon.connect_start" }?["cat"] as? String == "daemon")
        let task = try #require(events.first { $0["name"] as? String == "startup.theme" })
        #expect(task["ph"] as? String == "X")
        #expect(task["ts"] as? Double == 4)
        #expect(task["dur"] as? Double == 2.5)
        let turn = try #require(events.first { $0["name"] as? String == "main_turn" })
        #expect(turn["dur"] as? Double == 2_000)
        let lane = try #require(events.first { $0["name"] as? String == "lane.files" })
        #expect(lane["ph"] as? String == "X")
        #expect((lane["args"] as? [String: Any])?["priority"] as? String == WorkPriority.userVisible.description)
        #expect(events.contains { $0["name"] as? String == "process_name" && $0["ph"] as? String == "M" })
        let footer = try #require(events.last)
        #expect(footer["name"] as? String == "startup_trace.closed")

        // Closed: later records are dropped and a second close does nothing.
        trace.mark("late")
        trace.close()
        #expect(trace.status.pending == 0)
        #expect(!(try Self.read(file)).contains("\"late\""))
    }

    /// A trace cut off before its close (a crash, `kill -9`) has no `]`; its writes end on an event, so it
    /// still loads. Small writes: the records span many of them.
    @Test func aTruncatedChunkedFileStillParses() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        // `now` at the process start: the 5 s deadline is ahead (the host's real uptime is past it).
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: file, chunkBytes: 1_024),
                                 processStartNanos: 0, clock: ManualClock(), now: { 0 })
        let work = BackgroundWork(label: "test.startup-trace")
        trace.start(writingOn: work)
        for index in 0..<500 { trace.mark("mark \"\(index)\"\n") }
        let status = await trace.flush()
        #expect(!status.closed)
        let text = try Self.read(file)
        #expect(text.utf8.count > 8 * 1_024)
        #expect(!text.contains("]"))
        let events = try Self.parse(text)
        let names = events.compactMap { $0["name"] as? String }.filter { $0.hasPrefix("mark ") }
        #expect(names.count == 500)
        #expect(names.first == "mark \"0\"\n")
        #expect(names.last == "mark \"499\"\n")
    }

    /// A record from the main thread that makes a drain due does not write: the drain is posted to the files
    /// lane (held here behind a gate, so a write on the caller would show in the file), and the drain's write
    /// runs on a lane thread, not the caller's.
    @MainActor
    @Test func aDueDrainWritesOnTheFilesLaneNotOnTheMainThread() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        // 1 KiB writes and 8 records: a drain is due at 4 pending records.
        // `now` at the process start: the 5 s deadline is ahead (the host's real uptime is past it).
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: file, capacity: 8, chunkBytes: 1_024),
                                 processStartNanos: 0, clock: ManualClock(), now: { 0 })
        // One slot per priority, so the gate below holds the drains.
        let work = BackgroundWork(filesWidths: .serial, label: "test.startup-trace", onRan: trace.laneJobSink)
        trace.start(writingOn: work)
        _ = await trace.flush()
        let gate = DispatchSemaphore(value: 0)
        // The test's own hold on the drains' one user-visible slot: it may block (a files-lane item).
        work.post(.userVisible, mayBlock: .files) { gate.wait() }
        let main = StartupTrace.threadID()
        for index in 0..<4 { trace.mark("on_main_\(index)") }
        #expect(!(try Self.read(file)).contains("on_main"))
        gate.signal()
        _ = await trace.flush()
        _ = await trace.flush() // the lane slices of the drains above
        let events = try Self.parse(try Self.read(file))
        let marks = events.filter { ($0["name"] as? String)?.hasPrefix("on_main_") == true }
        #expect(marks.count == 4)
        #expect(marks.allSatisfy { ($0["tid"] as? NSNumber)?.uint64Value == main })
        let lanes = events.filter { $0["name"] as? String == "lane.files" }
        #expect(!lanes.isEmpty)
        #expect(lanes.allSatisfy { ($0["tid"] as? NSNumber)?.uint64Value != main })
    }

    /// A few records reach the file within the flush interval with no flush, no close and no full ring:
    /// a crash in the first second keeps what it recorded.
    @Test func aFewRecordsReachTheFileOnThePeriodicDrain() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = ManualClock()
        let configuration = StartupTraceConfiguration(seconds: StartupTraceConfiguration.maximumSeconds, file: file)
        let trace = StartupTrace(configuration: configuration, processStartNanos: 0, clock: clock, now: { 1_000 })
        let drained = Started()
        let work = BackgroundWork(label: "test.startup-trace", onRan: { _, _, _, _ in drained.signal() })
        trace.start(writingOn: work)
        _ = await trace.flush()
        await drained.wait(2) // the start's drain and the flush
        trace.mark("early_one")
        trace.mark("early_two")
        // The deadline and the periodic drain both sleep on the clock.
        await Self.waitForSleepers(clock, count: 2)
        clock.advance(by: configuration.flushInterval)
        await drained.wait()
        let text = try Self.read(file)
        #expect(text.contains("early_one"))
        #expect(text.contains("early_two"))
        #expect(!trace.status.closed)
    }

    /// Close hooks run once, after the file closed; a hook added after the close runs at once. The app
    /// takes the watchdog's main-turn sink and BackgroundWork's run reports off with them.
    @Test func closeHooksRunOnceAfterTheClose() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        // `now` at the process start: the 5 s deadline is ahead (the host's real uptime is past it).
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: file), processStartNanos: 0,
                                 clock: ManualClock(), now: { 0 })
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        trace.whenClosed { calls.withLock { $0.append("before") } }
        trace.start(writingOn: BackgroundWork(label: "test.startup-trace"))
        _ = await trace.flush()
        #expect(calls.withLock { $0 }.isEmpty)
        trace.close()
        let closed = await Self.waitUntilClosed(trace)
        #expect(closed.closed)
        #expect(calls.withLock { $0 } == ["before"])
        trace.whenClosed { calls.withLock { $0.append("after") } }
        trace.close()
        _ = await trace.flush()
        #expect(calls.withLock { $0 } == ["before", "after"])
    }

    /// The deadline closes the trace `seconds` after process start.
    @Test func theDeadlineClosesTheTrace() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = ManualClock()
        let trace = StartupTrace(configuration: StartupTraceConfiguration(seconds: 5, file: file), processStartNanos: 0,
                                 clock: clock, now: { 1_000_000_000 })
        trace.start(writingOn: BackgroundWork(label: "test.startup-trace"))
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(3))
        #expect(!(await trace.flush()).closed)
        clock.advance(by: .seconds(1))
        let closed = await Self.waitUntilClosed(trace)
        #expect(closed.closed)
        #expect(try Self.read(file).hasSuffix("]\n"))
    }

    // MARK: helpers

    private static func configuration(_ environment: [String: String]) -> StartupTraceConfiguration? {
        StartupTraceConfiguration.fromEnvironment({ environment[$0] }, home: URL(fileURLWithPath: "/h"), pid: 7)
    }

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "startup-trace-\(UUID().uuidString)/trace.json")
    }

    private static func read(_ file: URL) throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    /// Parses a trace as ui.perfetto.dev does: a JSON array whose closing `]` may be missing.
    private static func parse(_ text: String) throws -> [[String: Any]] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = trimmed.hasSuffix("]") ? trimmed : trimmed + "]"
        let value = try JSONSerialization.jsonObject(with: Data(whole.utf8))
        return try #require(value as? [[String: Any]])
    }

    /// Yields until `count` tasks sleep on `clock` (timers arm on their own tasks).
    private static func waitForSleepers(_ clock: ManualClock, count: Int) async {
        for _ in 0..<10_000 where clock.sleeperCount < count { await Task.yield() }
        #expect(clock.sleeperCount >= count)
    }

    /// Flushes until the close (posted on the files lane by the deadline or `close()`) has run.
    private static func waitUntilClosed(_ trace: StartupTrace) async -> StartupTrace.Status {
        var status = await trace.flush()
        for _ in 0..<500 where !status.closed {
            await Task.yield()
            status = await trace.flush()
        }
        return status
    }
}

/// The wall clock a test sets while the clock reader reads it.
private nonisolated final class WallClock: Sendable {
    private let value: Mutex<UInt64>

    init(_ nanos: UInt64) {
        value = Mutex(nanos)
    }

    var nanos: UInt64 { value.withLock { $0 } }

    func set(_ nanos: UInt64) {
        value.withLock { $0 = nanos }
    }
}

/// Lane items (synchronous) report that they ran; the async test awaits the reports.
nonisolated private struct Started: Sendable {  // signalled from a lane thread (onRan)
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

    func signal() { continuation.yield() }

    func wait(_ count: Int = 1) async {
        var left = count
        for await _ in stream {
            left -= 1
            if left == 0 { return }
        }
    }
}
