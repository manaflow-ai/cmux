@testable import CmuxNextBrowser
import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing

/// Chromium tracing in Release (p09-observability task 051): `trace.start chromium:true` begins it where
/// `CefInitialize` ran (the in-process shim's exports of task 050, or the host's TRACE_START wire of task
/// 104), and the stop writes Chromium's JSON and a meta.json with the measured clock offset into the
/// recording directory. A shim or host without the exports reports unsupported.
@Suite(.serialized) struct CEFTracingTests {
    @Test func inProcessStartAndStopWriteTheTraceAndItsMeta() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = try Self.runtime(TracingSpy.library())
        let tracing = Self.tracing(directory) { runtime.tracingBackend(hostWire: nil) }

        let started = try await tracing.start()
        #expect(started.mode == .inProcess)
        #expect(TracingSpy.categories == ["toplevel,cc,viz,gpu,input,latencyInfo,benchmark"])
        #expect(started.clock?.offsetNanos == 7000, "local midpoint 5_000_001_000 ns minus Chromium's 4_999_994 µs")
        #expect(started.clock?.errorBoundNanos == 2000, "half the 2 µs read window plus 1 µs truncation")

        let stopped = try await tracing.stop()
        #expect(stopped.mode == .inProcess)
        #expect(stopped.path == directory + "/chromium-4242.trace.json")
        #expect(TracingSpy.endPaths == [stopped.path])
        #expect(FileManager.default.fileExists(atPath: stopped.path), "Chromium's JSON is in the recording directory")
        #expect(stopped.clock?.offsetNanos == 7000, "a tie keeps the start sample")
        let meta = try Self.meta(try #require(stopped.metaPath))
        #expect(stopped.metaPath == directory + "/chromium-4242.meta.json")
        #expect(meta["mode"] as? String == "in_process")
        #expect(meta["trace"] as? String == "chromium-4242.trace.json")
        #expect(meta["requested_buffer_kb"] as? Int == 65536)
        #expect(meta["buffer_applied"] as? Bool == false)
        let clock = try #require(meta["clock"] as? [String: Any])
        #expect(clock["offset_ns"] as? Int == 7000)
        #expect(clock["error_bound_ns"] as? Int == 2000)
        let samples = try #require(meta["samples"] as? [[String: Any]])
        #expect(samples.compactMap { $0["offset_ns"] as? Int } == [7000, 11000], "start, then stop")
    }

    @Test func aShimWithoutTheTracingExportsIsUnsupported() async throws {
        let runtime = try Self.runtime(TracingSpy.library(tracingExports: false))
        let tracing = Self.tracing(Self.directory()) { runtime.tracingBackend(hostWire: nil) }
        await #expect(throws: CEFTracingError.unsupported(.missingShimSymbol)) { try await tracing.start() }
    }

    @Test func chromiumNotRunningIsUnsupported() async {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: URL(fileURLWithPath: Self.directory())))
        _ = Unmanaged.passRetained(runtime)
        let tracing = Self.tracing(Self.directory()) { runtime.tracingBackend(hostWire: nil) }
        await #expect(throws: CEFTracingError.unsupported(.chromiumNotRunning)) { try await tracing.start() }
    }

    @Test func hostModeIsUnsupportedUntilTheHostHasItsWire() async throws {
        let runtime = try Self.runtime(TracingSpy.library())
        runtime.hostStart = CEFHostStart(supervisor: NoHost())
        let tracing = Self.tracing(Self.directory()) { runtime.tracingBackend(hostWire: nil) }
        await #expect(throws: CEFTracingError.unsupported(.noHostWire)) { try await tracing.start() }
        #expect(TracingSpy.categories.isEmpty, "host mode never calls the in-process exports")
    }

    @Test func hostModeTracesThroughTheHostWire() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = try Self.runtime(TracingSpy.library())
        runtime.hostStart = CEFHostStart(supervisor: NoHost())
        let wire = HostWire()
        let tracing = Self.tracing(directory) { runtime.tracingBackend(hostWire: wire) }

        let started = try await tracing.start()
        #expect(started.mode == .host)
        #expect(wire.began == ["toplevel,cc,viz,gpu,input,latencyInfo,benchmark"])
        let stopped = try await tracing.stop()
        #expect(wire.ended == [directory + "/chromium-4242.trace.json"])
        #expect(FileManager.default.fileExists(atPath: stopped.path))
        let meta = try Self.meta(try #require(stopped.metaPath))
        #expect(meta["mode"] as? String == "host")
        #expect((meta["clock"] as? [String: Any])?["offset_ns"] as? Int == 7000)
        #expect(TracingSpy.categories.isEmpty, "host mode never calls the in-process exports")
    }

    @Test func aRefusedStartLeavesTracingIdle() async throws {
        let runtime = try Self.runtime(TracingSpy.library())
        let tracing = Self.tracing(Self.directory()) { runtime.tracingBackend(hostWire: nil) }
        TracingSpy.beginAnswer = 0
        await #expect(throws: CEFTracingError.refused) { try await tracing.start() }
        await #expect(throws: CEFTracingError.notTracing) { try await tracing.stop() }
        TracingSpy.posts = 0
        await #expect(throws: CEFTracingError.refused, "nothing posted: the start fails at once") { try await tracing.start() }
        TracingSpy.posts = 1
        TracingSpy.beginAnswer = 1
        _ = try await tracing.start()
        await #expect(throws: CEFTracingError.alreadyTracing) { try await tracing.start() }
    }

    @Test func aStopWithNoFileEndsTheRecording() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = try Self.runtime(TracingSpy.library())
        let tracing = Self.tracing(directory) { runtime.tracingBackend(hostWire: nil) }
        _ = try await tracing.start()
        TracingSpy.write = .nothing
        await #expect(throws: CEFTracingError.notWritten) { try await tracing.stop() }
        await #expect(throws: CEFTracingError.notTracing) { try await tracing.stop() }
        _ = try await tracing.start()
    }

    /// Chromium reports its path when it could not create the file (shim_tracing.mm): no file is no trace,
    /// and no meta.json points at one.
    @Test func aReportedPathWithNoFileIsNotWritten() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = try Self.runtime(TracingSpy.library())
        let tracing = Self.tracing(directory) { runtime.tracingBackend(hostWire: nil) }
        _ = try await tracing.start()
        TracingSpy.write = .pathOnly
        await #expect(throws: CEFTracingError.notWritten) { try await tracing.stop() }
        #expect(TracingSpy.endPaths == [directory + "/chromium-4242.trace.json"])
        #expect(!FileManager.default.fileExists(atPath: directory + "/chromium-4242.meta.json"))
    }

    @Test func aTruncatedTraceIsRefused() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = try Self.runtime(TracingSpy.library())
        let tracing = Self.tracing(directory) { runtime.tracingBackend(hostWire: nil) }
        _ = try await tracing.start()
        TracingSpy.write = .truncated
        await #expect(throws: CEFTracingError.truncated) { try await tracing.stop() }
        #expect(!FileManager.default.fileExists(atPath: directory + "/chromium-4242.meta.json"))
        await #expect(throws: CEFTracingError.notTracing, "the recording ended") { try await tracing.stop() }
    }

    /// The file names are fixed per pid: an earlier recording's trace and meta.json are removed before the end, so
    /// a recording Chromium did not write cannot pass for this one.
    @Test func anEarlierRecordingsFilesDoNotPassForThisOne() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let oldTrace = directory + "/chromium-4242.trace.json", oldMeta = directory + "/chromium-4242.meta.json"
        #expect(FileManager.default.createFile(atPath: oldTrace, contents: TracingSpy.wholeTrace))
        #expect(FileManager.default.createFile(atPath: oldMeta, contents: Data("{}".utf8)))
        let runtime = try Self.runtime(TracingSpy.library())
        let tracing = Self.tracing(directory) { runtime.tracingBackend(hostWire: nil) }
        _ = try await tracing.start()
        TracingSpy.write = .pathOnly
        await #expect(throws: CEFTracingError.notWritten) { try await tracing.stop() }
        #expect(!FileManager.default.fileExists(atPath: oldTrace))
        #expect(!FileManager.default.fileExists(atPath: oldMeta))
    }

    /// A directory that cannot be made (a file holds its name) is reported, and Chromium is still told to stop.
    @Test func aDirectoryThatCannotBeMadeIsReportedAndTheRecordingEnds() async throws {
        let parent = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: parent) }
        #expect(FileManager.default.createFile(atPath: parent, contents: Data("not a folder".utf8)))
        let runtime = try Self.runtime(TracingSpy.library())
        let tracing = Self.tracing(parent + "/trace") { runtime.tracingBackend(hostWire: nil) }
        _ = try await tracing.start()
        await #expect(throws: CEFTracingError.directoryUnavailable) { try await tracing.stop() }
        #expect(TracingSpy.endPaths == [parent + "/trace/chromium-4242.trace.json"], "Chromium's recording ended")
        await #expect(throws: CEFTracingError.notTracing) { try await tracing.stop() }
    }

    /// `trace.start` and `trace.stop` report through ``CEFTracing/startReport()`` and ``CEFTracing/stopReport()``.
    @Test func theReportsCarryTheFileTheOffsetAndTheErrorCode() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let runtime = try Self.runtime(TracingSpy.library())
        let tracing = Self.tracing(directory) { runtime.tracingBackend(hostWire: nil) }

        let started = await tracing.startReport()
        #expect(started == ChromiumTraceReport(state: .recording, mode: "in_process", categories: CEFTracing.categories,
                                               offsetNanos: 7000, errorBoundNanos: 2000))
        let stopped = await tracing.stopReport()
        #expect(stopped == ChromiumTraceReport(state: .stopped, mode: "in_process", path: directory + "/chromium-4242.trace.json",
                                               metaPath: directory + "/chromium-4242.meta.json", offsetNanos: 7000, errorBoundNanos: 2000))
        #expect(await tracing.stopReport() == ChromiumTraceReport(state: .error, error: "not_tracing"))

        let unsupported = try Self.runtime(TracingSpy.library(tracingExports: false))
        let missing = Self.tracing(directory) { unsupported.tracingBackend(hostWire: nil) }
        #expect(await missing.startReport() == ChromiumTraceReport(state: .untraced, error: "unsupported", detail: "missing_shim_symbol"))
    }

    @Test func theTraceCheckReadsBothEnds() {
        let check = CEFTracing.Files.isWholeTrace
        #expect(check(Data(#"{"traceEvents":["#.utf8), Data("]}\n".utf8)))
        #expect(!check(Data(#"{"traceEvents":["#.utf8), Data(#"{"ph":"X""#.utf8)), "cut before the closing brace")
        #expect(!check(Data(#"{"other":1}"#.utf8), Data("}".utf8)), "not a trace")
        #expect(!check(Data("garbage".utf8), Data("}".utf8)))
    }

    @Test func theTighterSampleWins() {
        let wide = CEFTracing.ClockSample(before: 1_000_000, chromiumMicros: 990, after: 1_010_000)
        let narrow = CEFTracing.ClockSample(before: 2_000_000, chromiumMicros: 1_990, after: 2_000_200)
        #expect(wide.errorBoundNanos == 6000)
        #expect(narrow.errorBoundNanos == 1100)
        #expect(narrow.offsetNanos == 10_100)
        #expect(CEFTracing.ClockSample.tighter(wide, narrow) == narrow)
        #expect(CEFTracing.ClockSample.tighter(nil, wide) == wide)
        #expect(CEFTracing.ClockSample.tighter(nil, nil) == nil)
        let backwards = CEFTracing.ClockSample(before: 5000, chromiumMicros: 4, after: 4000)
        #expect(backwards.errorBoundNanos == 1000, "a clock read that went back has no window")
    }

    // MARK: - Fixtures

    private static func directory() -> String {
        FileManager.default.temporaryDirectory.appending(path: "cef-tracing-\(UUID().uuidString)").path
    }

    private static func runtime(_ shim: CEFShimLibrary) throws -> CEFRuntime {
        TracingSpy.reset()
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: URL(fileURLWithPath: directory())))
        _ = Unmanaged.passRetained(runtime)
        return runtime
    }

    /// Local reads 2 µs apart from 5 s: the start samples 5_000_000_000 and 5_000_002_000, the stop 4 µs later.
    private static func tracing(_ directory: String, backend: @escaping () -> CEFTracing.Backend) -> CEFTracing {
        TracingSpy.reads = 0
        let reader = TraceClock.Reader(uptimeNanos: {
            defer { TracingSpy.reads += 1 }
            return 5_000_000_000 + UInt64(TracingSpy.reads) * 2000
        }, continuousNow: { ContinuousClock.now })
        return CEFTracing(directory: directory, work: BackgroundWork(label: "test.cef-tracing"), pid: 4242,
                          clock: TraceClock(reader: reader), backend: backend)
    }

    private static func meta(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// Stand-in tracing exports (a C function captures nothing, so their state is static).
private nonisolated enum TracingSpy {
    /// Chromium's clock: 4_999_994 µs, 7 µs behind the start sample's local midpoint.
    static let nowMicros: Int64 = 4_999_994
    /// A whole trace as Chromium's file endpoint writes one.
    static let wholeTrace = Data((#"{"traceEvents":[{"ph":"X","ts":1}],"metadata":{}}"# + "\n").utf8)
    nonisolated(unsafe) static var categories: [String] = []
    nonisolated(unsafe) static var endPaths: [String] = []
    /// What `started` answers.
    nonisolated(unsafe) static var beginAnswer: Int32 = 1
    /// What begin returns: 1 posted.
    nonisolated(unsafe) static var posts: Int32 = 1
    /// What end leaves at its path and reports.
    nonisolated(unsafe) static var write = Write.complete
    /// The injected local clock's read count.
    nonisolated(unsafe) static var reads = 0

    static func reset() {
        categories = []
        endPaths = []
        beginAnswer = 1
        posts = 1
        write = .complete
    }

    /// End's outcomes: Chromium reports its path whether or not the file it wrote there is whole.
    enum Write {
        /// A whole JSON trace, and its path.
        case complete
        /// The path, with no file written (Chromium could not create it).
        case pathOnly
        /// The path, with a trace cut short (a full disk).
        case truncated
        /// NULL: no recording ran.
        case nothing
    }

    static func library(tracingExports: Bool = true) throws -> CEFShimLibrary {
        let begin: CEFShimTracing.BeginFn = { categories, started, context in
            guard TracingSpy.posts == 1 else { return 0 }
            TracingSpy.categories.append(categories.map { String(cString: $0) } ?? "")
            started?(context, TracingSpy.beginAnswer)
            return 1
        }
        let end: CEFShimTracing.EndFn = { path, written, context in
            let file = path.map { String(cString: $0) } ?? ""
            TracingSpy.endPaths.append(file)
            switch TracingSpy.write {
            case .nothing:
                written?(context, nil)
                return 1
            case .pathOnly: break
            case .complete: _ = FileManager.default.createFile(atPath: file, contents: TracingSpy.wholeTrace)
            case .truncated: _ = FileManager.default.createFile(atPath: file, contents: Data(#"{"traceEvents":[{"ph":"X","ts":1"#.utf8))
            }
            file.withCString { written?(context, $0) }
            return 1
        }
        let now: @convention(c) () -> Int64 = { TracingSpy.nowMicros }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_cef_begin_tracing": tracingExports ? unsafeBitCast(begin, to: UnsafeMutableRawPointer.self) : nil
            case "cmux_cef_end_tracing": tracingExports ? unsafeBitCast(end, to: UnsafeMutableRawPointer.self) : nil
            case "cmux_cef_now_trace_us": tracingExports ? unsafeBitCast(now, to: UnsafeMutableRawPointer.self) : nil
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}

/// The host's TRACE_START and TRACE_STOP (task 104), answered here.
private final class HostWire: ChromiumHostTracing {
    var began: [String] = []
    var ended: [String] = []

    func beginTracing(categories: String) async -> Bool {
        began.append(categories)
        return true
    }

    func endTracing(path: String) async -> String? {
        ended.append(path)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return FileManager.default.createFile(atPath: path, contents: Data(#"{"traceEvents":[]}"#.utf8)) ? path : nil
    }

    func nowTraceMicros() async -> Int64? { TracingSpy.nowMicros }
}

private final class NoHost: ChromiumHostSupervising {
    func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        throw .cannotStart("not started in this test")
    }

    func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {}
}
