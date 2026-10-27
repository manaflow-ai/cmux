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

/// Chromium Host observability on cmux's side (p09-observability-104): the trace folders every bundled host gets,
/// the input flow ids both sides derive (the C++ side checks the same values in host_tracing_test.cpp), the crash
/// report of a host's end with its crash keys and black-box tail, its rate limit, the stability count of every
/// end, and the ended host's live-only files.
@MainActor @Suite struct ChromiumHostEndReportTests {
    @Test func theHostGetsItsTraceFoldersAsArguments() {
        let files = ChromiumHostTraceFiles(traceDirectory: "/t", metricsDirectory: "/m")
        #expect(files.arguments == ["--trace-dir=/t", "--metrics-dir=/m"])
        #expect(ChromiumHostTraceFiles(traceDirectory: "/t").arguments == ["--trace-dir=/t"])
        #expect(ChromiumHostTraceFiles(arguments: ["--x=1"] + files.arguments) == files, "a configuration reads its folders back")
        #expect(ChromiumHostTraceFiles(arguments: ["--metrics-dir=/m"]) == nil, "no trace folder: none")
        #expect(files.blackBoxPath(pid: 42) == "/t/chromium-host-42.blackbox.cmxtrace")
        #expect(files.crashKeysPath(pid: 42) == "/t/chromium-host-42.crashkeys")
        #expect(files.liveOnlyPaths(pid: 42) == ["/t/chromium-host-42.recording.cmxtrace", "/m/metrics-chromium-host-42.bin"])

        let home = URL(filePath: "/Users/someone")
        let app = ChromiumHostTraceFiles.app(bundleID: "com.cmuxterm.app.debug.t", home: home)
        #expect(app.traceDirectory == "/Users/someone/Library/Logs/com.cmuxterm.app.debug.t/trace")
        #expect(app.metricsDirectory == "/Users/someone/Library/Logs/com.cmuxterm.app.debug.t/metrics")
    }

    /// Every bundled host, the prototype's and host mode's (task p01-process-080 spawns from the same
    /// configuration), writes into the app's folders.
    @Test func aBundledHostWritesIntoTheAppsFolders() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chromium-host-trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "cmux DEV t.app")
        let frameworks = app.appending(path: "Contents/Frameworks")
        let layout = CEFRuntimeLayout(frameworksDirectory: frameworks, mainBundle: app,
                                      helperApp: frameworks.appending(path: "cmux DEV t Helper.app"))
        let host = app.appending(path: "Contents/MacOS/cmux DEV t Chromium Host")
        try FileManager.default.createDirectory(at: host.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: host.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        let configuration = try #require(ChromiumHostConfiguration.bundled(in: layout, rootCache: root, bundleIdentifier: "t",
                                                                           environment: [:]))
        #expect(configuration.traceFiles == ChromiumHostTraceFiles.app(bundleID: "t"))
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
        #expect(limit.allows("SIGSEGV"))
        #expect(!limit.allows("SIGSEGV"), "a second SIGSEGV within the hour")
        #expect(limit.allows("SIGTRAP"), "another way of ending has its own hour")
        clock.advance(by: .seconds(59 * 60))
        #expect(!limit.allows("SIGSEGV"))
        clock.advance(by: .seconds(60))
        #expect(limit.allows("SIGSEGV"), "an hour later")
    }

    @Test func aHostEndCountsByHowItEnded() throws {
        #expect(try #require(ChromiumHostExit(signal: SIGSEGV, status: nil).pageExit).stabilityExit == .signal)
        #expect(try #require(ChromiumHostExit(signal: SIGKILL, status: nil).pageExit).stabilityExit == .signal)
        #expect(try #require(ChromiumHostExit(signal: nil, status: 68).pageExit).stabilityExit == .panic)
        #expect(try #require(ChromiumHostExit(signal: nil, status: nil).pageExit).stabilityExit == .signal)
        #expect(BrowserProcessExit(reason: .outOfMemory, engine: .cef, process: .chromiumHost).stabilityExit == .oom)
        #expect(ChromiumHostExit(signal: nil, status: 0).pageExit == nil, "a clean exit has no page exit: it counts as clean")
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

        let segv = try #require(ChromiumHostExit(signal: SIGSEGV, status: nil).pageExit)
        let report = ChromiumHostEndReport(pid: Int32(pid), exit: segv, restarts: 1,
                                           budget: ChromiumHostEndReport.Budget(recentCrashes: 1, decision: "restart"),
                                           blackBoxPath: files.blackBoxPath(pid: Int32(pid)), crashKeysPath: files.crashKeysPath(pid: Int32(pid)))
        let details = report.details(hangReportsOptIn: true)
        #expect(details.type == "ChromiumHostExit")
        #expect(details.fingerprint == ["chromium-host-exit", "SIGSEGV"])
        #expect(details.tags["chromium_host.exit"] == "SIGSEGV" && details.tags["chromium_host.reason"] == "crashed")
        #expect(details.tags["chromium_host.decision"] == "restart")
        #expect(details.tags["crash_key.cef_api_version"] == "31")
        #expect(details.tags["crash_key.in_cef_pump"] == "1")
        #expect(details.extra["restarts"] == "1" && details.extra["recent_crashes"] == "1")
        let tail = try #require(details.extra["blackbox_tail"])
        #expect(tail.contains("chromium-host cef.pump"))

        #expect(report.details(hangReportsOptIn: false).extra["blackbox_tail"] == nil, "no opt-in: no black box")
        var hostMode = report
        hostMode.budget = nil
        #expect(hostMode.details(hangReportsOptIn: false).tags["chromium_host.decision"] == nil, "host mode has no budget")
        var other = report
        other.pid = 7
        #expect(other.details(hangReportsOptIn: true).tags["crash_key.cef_api_version"] == nil,
                "another process's page is not this host's")
    }

    /// The ended host's recording ring and metrics file go, off the main thread; its black box and crash keys stay
    /// for the report.
    @Test func forgettingAHostDeletesOnlyItsLiveOnlyFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "host-forget-\(UUID().uuidString)")
        let metrics = folder.appending(path: "metrics")
        try FileManager.default.createDirectory(at: metrics, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ChromiumHostTraceFiles(traceDirectory: folder.path, metricsDirectory: metrics.path)
        let kept = [files.blackBoxPath(pid: 42), files.crashKeysPath(pid: 42)] + files.liveOnlyPaths(pid: 43)
        for path in files.liveOnlyPaths(pid: 42) + kept {
            #expect(FileManager.default.createFile(atPath: path, contents: Data([1])))
        }
        let posted = PostedFiles()
        let reports = ChromiumHostEndReports(traceFiles: files, limit: ChromiumHostEndReportLimit(), metrics: Metrics(),
                                             postFiles: { posted.add($0) }, send: { _ in })

        reports.forget(pid: 42)
        #expect(files.liveOnlyPaths(pid: 42).allSatisfy { FileManager.default.fileExists(atPath: $0) }, "nothing on the main thread")
        posted.run()
        #expect(files.liveOnlyPaths(pid: 42).allSatisfy { !FileManager.default.fileExists(atPath: $0) })
        #expect(kept.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "the black box, the keys and other hosts' files stay")
        reports.forget(pid: 0)
        #expect(posted.count == 1, "no pid: nothing to forget")
    }
}

/// File work the reports posted, run when the test says.
nonisolated final class PostedFiles: Sendable {
    private let work = Mutex<[@Sendable () -> Void]>([])

    var count: Int { work.withLock { $0.count } }

    func add(_ body: @escaping @Sendable () -> Void) {
        work.withLock { $0.append(body) }
    }

    func run() {
        for body in work.withLock({ $0 }) { body() }
    }
}

/// The reports a ``ChromiumHostEndReports`` sent.
@MainActor final class SentReports {
    var reports: [ChromiumHostEndReport] = []
}

/// A metrics store on its own trace runtime that counts host ends.
@MainActor func hostEndStore() -> (Metrics, MetricsStore) {
    let runtime = TraceRuntime(role: .app)
    let store = MetricsStore(role: .app, profile: MetricsProfile(appVersion: "1", buildNumber: "1", channel: "test", osVersion: "26",
                                                                hardwareClass: "Mac", bootSessionUUID: [], buildUUID: [],
                                                                buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 27)),
                             pid: 1, catalog: [.stabilityChildExit(.chromiumHost)])
    #expect(store.attach(to: runtime))
    return (Metrics(runtime: runtime), store)
}

/// How many ends of each kind `store` counted.
@MainActor func hostEndCounts(_ store: MetricsStore) throws -> (total: UInt64, signal: UInt64, clean: UInt64) {
    let counts = try #require(store.delta().histograms.first { $0.name == HistogramID.stabilityChildExit(.chromiumHost).name })
    let layout = HistogramID.stabilityChildExit(.chromiumHost).layout
    let signal = try #require(layout.bucketIndex(of: HistogramID.ChildExit.signal.rawValue))
    let clean = try #require(layout.bucketIndex(of: HistogramID.ChildExit.clean.rawValue))
    return (UInt64(counts.count), UInt64(counts.buckets.first { $0.index == signal }?.count ?? 0),
            UInt64(counts.buckets.first { $0.index == clean }?.count ?? 0))
}

extension ChromiumHostSessionTests {
    /// A SIGSEGV of a running host: one crash report with the budget, one stability count and its files forgotten;
    /// a second SIGSEGV within the hour counts but sends nothing; a quit counts as clean and sends nothing.
    @Test func aHostCrashIsOneReportAndEveryEndCounts() async throws {
        let launcher = FakeLauncher()
        let (metrics, store) = hostEndStore()
        let sent = SentReports()
        let posted = PostedFiles()
        let reports = ChromiumHostEndReports(traceFiles: ChromiumHostTraceFiles(traceDirectory: "/nonexistent/trace"),
                                             limit: ChromiumHostEndReportLimit(), metrics: metrics,
                                             postFiles: { posted.add($0) }, send: { sent.reports.append($0) })
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, endReports: reports)
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        answer(first, context: 7, address: "https://a.example/")
        try await until("running") { session.phase == .running }

        launcher.end(first, ChromiumHostExit(signal: SIGSEGV, status: nil))
        let second = try await nextLaunch(launcher)
        #expect(sent.reports.count == 1)
        let report = try #require(sent.reports.first)
        #expect(report.pid == first.pid && report.exit.reason == .crashed && report.exitDescription == "SIGSEGV")
        #expect(report.restarts == 0, "no host ended by itself before this one")
        #expect(report.budget == ChromiumHostEndReport.Budget(recentCrashes: 1, decision: "restart"))
        #expect(report.blackBoxPath == "/nonexistent/trace/chromium-host-\(first.pid).blackbox.cmxtrace")
        #expect(posted.count == 1, "the ended host's files are forgotten")

        answer(second, context: 8, address: "https://a.example/")
        try await until("running again") { session.phase == .running }
        launcher.end(second, ChromiumHostExit(signal: SIGSEGV, status: nil))
        let third = try await nextLaunch(launcher)
        #expect(sent.reports.count == 1, "the same way of ending within the hour sends nothing")

        answer(third, context: 9, address: "https://a.example/")
        try await until("running a third time") { session.phase == .running }
        session.close()
        launcher.end(third, ChromiumHostExit(signal: nil, status: 0))
        try await until("idle") { session.phase == .idle }
        #expect(sent.reports.count == 1, "a quit is cmux's own end")
        #expect(posted.count == 3, "every end forgets its host's files")

        let counts = try hostEndCounts(store)
        #expect(counts.total == 3 && counts.signal == 2 && counts.clean == 1)
    }
}
#endif
