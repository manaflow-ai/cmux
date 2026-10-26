@testable import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
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
        let processStart = Date(timeIntervalSinceNow: -1)
        var marks = LaunchMarks()
        let early = marks.record("early", at: Date(), processStart: processStart)
        #expect(early.map { $0 >= 1_000 } == true)
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: Self.temporaryFile()), processStartNanos: 0,
                                 clock: ManualClock())
        marks.attach(trace, processStart: processStart)
        #expect(marks.trace === trace)
        let now = Date()
        #expect(marks.record("main_start", at: now, processStart: processStart) != nil)
        LaunchMarks.forward("main_start", at: now, to: marks.trace)
        #expect(marks.record("main_start", at: Date(), processStart: processStart) == nil)
        #expect(marks.all.map { $0.name } == ["early", "main_start"])
        #expect(trace.status.pending == 2)
    }

    // MARK: file

    /// Every kind of record, closed: the file is one JSON array that ends in `]`, with times in microseconds.
    @Test func aClosedTraceIsAFullChromeTraceFile() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: file), processStartNanos: 1_000,
                                 clock: ManualClock(), now: { 9_000_000 })
        let work = BackgroundWork(label: "test.startup-trace", onRan: trace.laneJobSink)
        trace.start(writingOn: work)
        trace.mark("main_start", at: 2_500)
        trace.mark("daemon.connect_start", at: 3_000)
        trace.task("startup.theme", start: 4_000, end: 6_500)
        trace.mainTurn(start: 7_000, end: 2_007_000)
        // Ahead of the close's drain on the same serial queue, so its record is in the ring by then.
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
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: file, chunkBytes: 1_024),
                                 processStartNanos: 0, clock: ManualClock())
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

    /// Recording never writes on the recording thread: the record reaches the file only through a drain on
    /// the files lane.
    @Test func recordingWritesNothingOnTheCallersThread() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let trace = StartupTrace(configuration: StartupTraceConfiguration(file: file), processStartNanos: 0,
                                 clock: ManualClock())
        let work = BackgroundWork(label: "test.startup-trace")
        trace.start(writingOn: work)
        _ = await trace.flush()
        trace.mark("on_main")
        #expect(!((try? Self.read(file)) ?? "").contains("on_main"))
        _ = await trace.flush()
        #expect(try Self.read(file).contains("on_main"))
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
