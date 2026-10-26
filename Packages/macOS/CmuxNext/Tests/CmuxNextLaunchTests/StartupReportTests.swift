#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextLaunch
import Foundation
import Testing

/// `debug.startup`'s payload (p08-startup task 008): every field is present in every report, a missing
/// producer reads `null`, and the derived fields follow the marks and records they come from.
@Suite struct StartupReportTests {
    static let fields: Set<String> = [
        "milestones", "interrupted", "temperature", "pageins_run_loop_start", "pageins_first_frame",
        "main_cpu_ms_to_first_frame", "tasks", "critical_violations", "reason", "views_built",
        "first_commit_layer_tree", "threads_at_first_frame", "trace_ring_bytes", "action_catalog_main_wait_ms",
    ]

    static func object(_ report: StartupReport) throws -> [String: Any] {
        try #require(try report.foundationObject() as? [String: Any])
    }

    @Test func anEmptyLaunchHasEveryFieldWithNullForEachMissingProducer() throws {
        let object = try Self.object(StartupReport(milestones: [], traceRingBytes: 0))
        #expect(Set(object.keys) == Self.fields)
        for key in Self.fields.subtracting(["milestones", "interrupted", "trace_ring_bytes"]) {
            #expect(object[key] is NSNull, "\(key) should be null")
        }
        #expect((object["milestones"] as? [String: Any])?.isEmpty == true)
        #expect(object["interrupted"] as? Bool == false)
        #expect(object["trace_ring_bytes"] as? Int == 0)
    }

    @Test func milestonesAreAnObjectThatKeepsTheFirstOfEachName() throws {
        let report = StartupReport(milestones: [.init(name: "main_start", ms: 3.25), .init(name: "run_loop_start", ms: 40.0004),
                                                .init(name: "main_start", ms: 9)],
                                   traceRingBytes: 1 << 20)
        let object = try Self.object(report)
        let milestones = try #require(object["milestones"] as? [String: Double])
        #expect(milestones == ["main_start": 3.25, "run_loop_start": 40])
        #expect(object["trace_ring_bytes"] as? Int == 1 << 20)
    }

    @Test func theTemperatureValueMarkFillsTheTemperature() throws {
        var counters = StartupReport.Counters()
        counters.record(StartupReport.temperatureValue, value: "cold")
        counters.record(StartupReport.temperatureValue, value: "warm")
        let report = StartupReport(milestones: [.init(name: "run_loop_start", ms: 40)], counters: counters, traceRingBytes: 0)
        #expect(report.temperature == "cold")
        #expect(try Self.object(report)["temperature"] as? String == "cold")
    }

    @Test func theValueMarkWinsOverTheInstantMarkWhenBothCame() {
        let report = StartupReport(milestones: [.init(name: "launch.temperature.warm", ms: 40)],
                                   counters: .init(temperature: "lukewarm"), traceRingBytes: 0)
        #expect(report.temperature == "lukewarm")
    }

    @Test func temperatureAndInterruptedComeFromTheirMarks() throws {
        let report = StartupReport(milestones: [.init(name: "run_loop_start", ms: 40), .init(name: "launch.temperature.cold", ms: 40),
                                                .init(name: StartupReport.interruptedMark, ms: 0)],
                                   traceRingBytes: 0)
        #expect(report.temperature == "cold")
        #expect(report.interrupted)
        let object = try Self.object(report)
        #expect(object["temperature"] as? String == "cold")
        #expect(object["interrupted"] as? Bool == true)
    }

    @Test func valueMarksFillThePageInsAndMainCPUFields() throws {
        var counters = StartupReport.Counters()
        counters.record(StartupReport.pageInsRunLoopStart, value: "3900")
        counters.record(StartupReport.pageInsFirstFrame, value: "4200.0")
        counters.record(StartupReport.pageInsFirstFrame, value: "9999")
        counters.record(StartupReport.mainCPUFirstFrame, value: "52.123456")
        counters.record("launch.unknown", value: "not a number")
        #expect(counters.values.count == 3)
        let report = StartupReport(milestones: [], counters: counters, traceRingBytes: 0)
        let object = try Self.object(report)
        #expect(object["pageins_run_loop_start"] as? Double == 3_900)
        #expect(object["pageins_first_frame"] as? Double == 4_200)
        #expect(object["main_cpu_ms_to_first_frame"] as? Double == 52.123)
    }

    @Test func schedulerTasksAreTimedFromProcessStartAndViolationsCounted() throws {
        let start: UInt64 = 5_000_000_000
        let tasks = [
            StartupReport.TaskRecord(name: "windows.restore", priority: "critical", destination: "main", processStartNanos: start,
                                     postedNanos: start + 10_000_000, startNanos: start + 10_500_000, durationNanos: 2_250_000,
                                     violation: nil),
            StartupReport.TaskRecord(name: "unlisted", priority: "critical", destination: "main", processStartNanos: start,
                                     postedNanos: start + 20_000_000, startNanos: nil, durationNanos: nil,
                                     violation: "notInCriticalAllowlist"),
            StartupReport.TaskRecord(name: "palette.prepare", priority: "onDemand", destination: "lane(cpu, idle)", processStartNanos: start,
                                     postedNanos: start - 1, startNanos: nil, durationNanos: nil, violation: "onDemandPosted"),
        ]
        let report = StartupReport(milestones: [], scheduler: .init(tasks: tasks, completionReason: "refsReleased"), traceRingBytes: 0)
        #expect(report.criticalViolations == 2)
        let object = try Self.object(report)
        #expect(object["critical_violations"] as? Int == 2)
        #expect(object["reason"] as? String == "refsReleased")
        let encoded = try #require(object["tasks"] as? [[String: Any]])
        #expect(encoded.count == 3)
        #expect(encoded[0]["name"] as? String == "windows.restore")
        #expect(encoded[0]["posted_ms"] as? Double == 10)
        #expect(encoded[0]["start_ms"] as? Double == 10.5)
        #expect(encoded[0]["duration_ms"] as? Double == 2.25)
        #expect(encoded[0]["violation"] is NSNull)
        #expect(encoded[1]["start_ms"] is NSNull)
        #expect(encoded[1]["duration_ms"] is NSNull)
        // A post recorded before the process-start reading clamps to 0, never a negative time.
        #expect(encoded[2]["posted_ms"] as? Double == 0)
        #expect(encoded[2]["destination"] as? String == "lane(cpu, idle)")
    }

    @Test func anEmptySchedulerIsAnEmptyListNotNull() throws {
        let object = try Self.object(StartupReport(milestones: [], scheduler: .init(tasks: [], completionReason: nil), traceRingBytes: 0))
        #expect((object["tasks"] as? [Any])?.isEmpty == true)
        #expect(object["critical_violations"] as? Int == 0)
        #expect(object["reason"] is NSNull)
    }

    @Test func aReportFromLaunchMarksCarriesTheirMarksAndTheCounters() {
        var marks = LaunchMarks()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = marks.record("main_start", at: start.addingTimeInterval(0.004), processStart: start)
        let report = StartupReport(launch: marks, counters: .init(values: [StartupReport.pageInsFirstFrame: 12]))
        #expect(report.milestones.map(\.name) == ["main_start"])
        #expect(abs((report.milestones.first?.ms ?? 0) - 4) < 0.001)
        #expect(report.counters?.values == [StartupReport.pageInsFirstFrame: 12])
        #expect(report.traceRingBytes == 0)
    }
}

/// The recorder keeps the first committed frame once and reads its sources when asked.
@MainActor
@Suite struct StartupReportRecorderTests {
    nonisolated struct FixedThreads: StartupThreadSource {
        func threads() -> [StartupReport.ThreadRecord] {
            [.init(id: 7, name: "", priority: 47, isMain: true), .init(id: 9, name: "cmux-next launch warm-up", priority: 31, isMain: false)]
        }
    }

    final class MaterialView: NSView {}
    final class PictureView: NSView {}

    /// A thread read the test finishes by hand: ``finish()`` is the reply's later main-thread post.
    @MainActor final class HeldThreadRead {
        private var pending: [@MainActor () -> Void] = []
        var asks: Int { pending.count }

        var read: StartupReportRecorder.ThreadRead {
            { [self] source, done in pending.append { done(source.threads()) } }
        }

        func finish() {
            let replies = pending
            pending = []
            for reply in replies { reply() }
        }
    }

    static func recorder(processStartNanos: UInt64 = 0,
                         scheduler: @escaping (UInt64) -> StartupReport.Scheduler? = { _ in nil },
                         actionCatalogMainWaitMs: @escaping () -> Double? = { nil }) -> StartupReportRecorder {
        StartupReportRecorder(launch: { LaunchMarks() }, processStartNanos: processStartNanos, counters: { nil },
                              scheduler: scheduler, actionCatalogMainWaitMs: actionCatalogMainWaitMs, threads: FixedThreads())
    }

    @Test func theFirstFrameIsKeptOnceWithTheSubviewTypesBackToFront() throws {
        let recorder = Self.recorder(), held = HeldThreadRead()
        #expect(recorder.report.firstFrame == nil)
        recorder.firstFrameCommitted(contentSubviews: [MaterialView(), PictureView()], viewsBuilt: 0, readThreads: held.read)
        recorder.firstFrameCommitted(contentSubviews: [NSView()], viewsBuilt: 4, readThreads: held.read)
        #expect(held.asks == 1)
        held.finish()
        let object = try StartupReportTests.object(recorder.report)
        #expect(object["first_commit_layer_tree"] as? [String] == ["MaterialView", "PictureView"])
        #expect(object["views_built"] as? Int == 0)
        let threads = try #require(object["threads_at_first_frame"] as? [[String: Any]])
        #expect(threads.count == 2)
        #expect(threads[0]["main"] as? Bool == true)
        #expect(threads[1]["name"] as? String == "cmux-next launch warm-up")
        #expect(threads[1]["priority"] as? Int == 31)
    }

    @Test func aWindowWithNoContentViewHasAnUnknownLayerTreeNotAnEmptyOne() throws {
        let recorder = Self.recorder()
        recorder.firstFrameCommitted(contentSubviews: nil, viewsBuilt: 0, readThreads: HeldThreadRead().read)
        let object = try StartupReportTests.object(recorder.report)
        #expect(object["first_commit_layer_tree"] is NSNull)
        #expect(object["views_built"] as? Int == 0)
    }

    @Test func theThreadListLandsAfterTheFirstFrameTurn() {
        let recorder = Self.recorder(), held = HeldThreadRead()
        recorder.firstFrameCommitted(contentSubviews: [], viewsBuilt: 0, readThreads: held.read)
        // Read off main after this turn: not yet in the report in the committing turn.
        #expect(recorder.firstFrame?.threads == nil)
        held.finish()
        #expect(recorder.firstFrame?.threads?.count == 2)
    }

    @Test func theSchedulerGetsTheProcessStartGivenAtInit() throws {
        var seen: [UInt64] = []
        let recorder = Self.recorder(processStartNanos: 123_456, scheduler: { start in
            seen.append(start)
            return .init(tasks: [], completionReason: nil)
        })
        _ = recorder.report
        _ = recorder.report
        #expect(seen == [123_456, 123_456])
    }

    @Test func theSchedulerAndActionCatalogSourcesAreReadAtEachReport() throws {
        var wait: Double?
        var reason: String?
        let recorder = Self.recorder(scheduler: { _ in .init(tasks: [], completionReason: reason) },
                                     actionCatalogMainWaitMs: { wait })
        #expect(try StartupReportTests.object(recorder.report)["action_catalog_main_wait_ms"] is NSNull)
        wait = 0
        reason = "refsReleased"
        let object = try StartupReportTests.object(recorder.report)
        #expect(object["action_catalog_main_wait_ms"] as? Double == 0)
        #expect(object["reason"] as? String == "refsReleased")
    }

    @Test func theSystemThreadListHasOneMainThreadAndNamesThisOne() {
        let name = "startup-report-test-\(UInt32.random(in: 0 ... .max))"
        let previous = Thread.current.name
        Thread.current.name = name
        defer { Thread.current.name = previous }
        let threads = SystemStartupThreads().threads()
        #expect(threads.count(where: \.isMain) == 1)
        #expect(threads.contains { $0.name == name })
        #expect(Set(threads.map(\.id)).count == threads.count)
    }
}
#endif
