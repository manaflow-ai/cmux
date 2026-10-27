#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// Chromium Host observability on cmux's side (p09-observability-104): the trace files and arguments each host
/// gets, the input flow ids both sides derive (the C++ side checks the same values in host_tracing_test.cpp),
/// the crash report of a host's end with its crash keys and black-box tail, and its rate limit.
@Suite struct ChromiumHostEndReportTests {
    @Test func theHostGetsItsTraceFoldersAsArguments() {
        let files = ChromiumHostTraceFiles(traceDirectory: "/t", metricsDirectory: "/m")
        #expect(files.arguments == ["--trace-dir=/t", "--metrics-dir=/m"])
        #expect(ChromiumHostTraceFiles(traceDirectory: "/t").arguments == ["--trace-dir=/t"])
        #expect(files.blackBoxPath(pid: 42) == "/t/chromium-host-42.blackbox.cmxtrace")
        #expect(files.crashKeysPath(pid: 42) == "/t/chromium-host-42.crashkeys")
    }

    @Test func inputFlowsAreTheHostsGolden() {
        #expect(ChromiumHostFrame.inputFlow(appPID: 1234, eventTime: 5_000_000_000) == 0x6631_9fa3_40c4_cc97)
        #expect(ChromiumHostFrame.inputFlow(appPID: 0xffff_ffff, eventTime: 1) == 0x4fa8_e9bd_8fd6_63a7)
        #expect(ChromiumHostFrame(.mouse, t0: 5_000_000_000).inputFlow(appPID: 1234) == 0x6631_9fa3_40c4_cc97)
        #expect(ChromiumHostFrame(.wheel, t0: 0).inputFlow(appPID: 1234) == nil, "no event time: no flow")
        #expect(ChromiumHostFrame(.key, t0: 7).inputFlow(appPID: 1234) == nil, "a key has no flow: its timing is typing")
        #expect(ChromiumHostFrame(.geometry, t0: 7).inputFlow(appPID: 1234) == nil)
    }

    @Test func oneReportPerWayOfEndingPerHour() {
        let clock = ManualClock()
        var limit = ChromiumHostEndReportLimit(clock: clock)
        #expect(limit.allows("signal 11"))
        #expect(!limit.allows("signal 11"), "a second SIGSEGV within the hour")
        #expect(limit.allows("signal 5"), "another way of ending has its own hour")
        clock.advance(by: .seconds(59 * 60))
        #expect(!limit.allows("signal 11"))
        clock.advance(by: .seconds(60))
        #expect(limit.allows("signal 11"), "an hour later")
    }

    @Test func aHostEndCountsByHowItEnded() {
        #expect(ChromiumHostExit(signal: SIGSEGV, status: nil).stabilityExit == .signal)
        #expect(ChromiumHostExit(signal: nil, status: 0).stabilityExit == .clean)
        #expect(ChromiumHostExit(signal: nil, status: 68).stabilityExit == .panic)
        #expect(ChromiumHostExit(signal: nil, status: nil).stabilityExit == .signal)
    }

    /// The details read the host's crash keys (its tags) and, with the opt-in only, its black-box tail of
    /// uploadable records.
    @Test func detailsCarryTheHostsKeysAndTail() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "host-end-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pid: UInt32 = 4242
        let files = ChromiumHostTraceFiles(traceDirectory: folder.path)

        let page = CrashKeyPage(identity: CrashKeyPage.Identity(pid: pid, role: .chromiumHost))
        page.set(.cefAPIVersion, 31)
        page.set(.inCEFPump, 1)
        #expect(page.adopt(directory: folder.path) != nil)

        let ring = TraceRing(sizes: TraceRing.Sizes(records: 64, nameCapacity: 1_024), identity: TraceRing.Identity(pid: pid, role: .chromiumHost),
                             catalog: SignpostName.traceCatalog)
        ring.write(name: SignpostName.cefPump.rawValue, phase: .begin, timestamp: 1_000, arg0: 1)
        ring.write(name: SignpostName.cefPump.rawValue, phase: .end, timestamp: 2_000, arg0: 0, arg1: 250)
        try Data(ring.image()).write(to: URL(fileURLWithPath: files.blackBoxPath(pid: Int32(pid))))

        let report = ChromiumHostEndReport(pid: Int32(pid), signal: SIGSEGV, status: nil, restarts: 1, recentCrashes: 1,
                                           decision: "restart", saidHello: true, blackBoxPath: files.blackBoxPath(pid: Int32(pid)),
                                           crashKeysPath: files.crashKeysPath(pid: Int32(pid)))
        let details = report.details(hangReportsOptIn: true)
        #expect(details.type == "ChromiumHostExit")
        #expect(details.fingerprint == ["chromium-host-exit", "signal 11"])
        #expect(details.tags["chromium_host.exit"] == "signal 11")
        #expect(details.tags["chromium_host.decision"] == "restart")
        #expect(details.tags["crash_key.cef_api_version"] == "31")
        #expect(details.tags["crash_key.in_cef_pump"] == "1")
        #expect(details.extra["restarts"] == "1" && details.extra["recent_crashes"] == "1")
        let tail = try #require(details.extra["blackbox_tail"])
        #expect(tail.contains("chromium-host cef.pump"))

        #expect(report.details(hangReportsOptIn: false).extra["blackbox_tail"] == nil, "no opt-in: no black box")
        var other = report
        other.pid = 7
        #expect(other.details(hangReportsOptIn: true).tags["crash_key.cef_api_version"] == nil,
                "another process's page is not this host's")
    }
}

/// The crash reports a session handed to the App.
@MainActor private final class SentReports {
    var reports: [ChromiumHostEndReport] = []
}

extension ChromiumHostSessionTests {
    /// A SIGSEGV of a running host: one crash report with the restart and the host's files, one stability count;
    /// a second SIGSEGV within the hour counts but sends nothing; a quit counts as clean and sends nothing.
    @Test func aHostCrashIsOneReportAndEveryEndCounts() async throws {
        let launcher = FakeLauncher()
        let runtime = TraceRuntime(role: .app)
        let store = MetricsStore(role: .app, profile: MetricsProfile(appVersion: "1", buildNumber: "1", channel: "test", osVersion: "26",
                                                                    hardwareClass: "Mac", bootSessionUUID: [], buildUUID: [],
                                                                    buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 27)),
                                 pid: 1, catalog: [.stabilityChildExit(.chromiumHost)])
        #expect(store.attach(to: runtime))
        let sent = SentReports()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, metrics: Metrics(runtime: runtime),
                                          hostEndReported: { sent.reports.append($0) })
        var reports: [ChromiumHostEndReport] { sent.reports }
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        answer(first, context: 7, address: "https://a.example/")
        try await until("running") { session.phase == .running }

        launcher.end(first, ChromiumHostExit(signal: SIGSEGV, status: nil))
        let second = try await nextLaunch(launcher)
        #expect(reports.count == 1)
        let report = try #require(reports.first)
        #expect(report.pid == first.pid && report.signal == SIGSEGV && report.restarts == 1)
        #expect(report.decision == "restart" && report.saidHello && report.recentCrashes == 1)
        #expect(report.blackBoxPath == nil, "the stand-in launcher gives no trace folder")

        answer(second, context: 8, address: "https://a.example/")
        try await until("running again") { session.phase == .running }
        launcher.end(second, ChromiumHostExit(signal: SIGSEGV, status: nil))
        let third = try await nextLaunch(launcher)
        #expect(reports.count == 1, "the same way of ending within the hour sends nothing")

        answer(third, context: 9, address: "https://a.example/")
        try await until("running a third time") { session.phase == .running }
        session.close()
        launcher.end(third, ChromiumHostExit(signal: nil, status: 0))
        try await until("idle") { session.phase == .idle }
        #expect(reports.count == 1, "a quit is cmux's own end")

        let counts = try #require(store.delta().histograms.first { $0.name == HistogramID.stabilityChildExit(.chromiumHost).name })
        #expect(counts.count == 3)
        let layout = HistogramID.stabilityChildExit(.chromiumHost).layout
        let signal = try #require(layout.bucketIndex(of: HistogramID.ChildExit.signal.rawValue))
        let clean = try #require(layout.bucketIndex(of: HistogramID.ChildExit.clean.rawValue))
        #expect(counts.buckets.first { $0.index == signal }?.count == 2)
        #expect(counts.buckets.first { $0.index == clean }?.count == 1)
    }
}
#endif
