#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextSettings
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// p01-process-085: an end of the Chromium Host becomes one crash report in the report folder and one `debug.crashes`
/// `chromium_host` row, both from `CrashReportWriter.report(for:)` of its record: its signal, what it ran and its log's last
/// lines.
@MainActor
@Suite struct ChromiumHostCrashReportTests {
    private static let trapped = ChromiumHostCrashRecord(
        date: Date(timeIntervalSince1970: 1_800_000_000), pid: 4242, signal: SIGTRAP, exitCode: nil, reason: .crashed,
        startFailure: nil, saidHello: true, cefVersion: "154.0.0", forkAPI: 30, logTail: ["[FATAL] navigating to <url>"])

    private static func writer() -> CrashReportWriter {
        CrashReportWriter(directory: FileManager.default.temporaryDirectory.appending(path: "host-crash-\(UUID().uuidString)",
                                                                                      directoryHint: .isDirectory),
                          bundleID: "com.cmuxterm.app.test", version: "1.0 1")
    }

    @Test func theReportNamesTheSignalWhatTheHostRanAndItsLogTail() throws {
        let report = try #require(JSONValue(foundation: Self.writer().report(for: Self.trapped))?.objectValue)
        #expect(report["kind"] == "chromium-host")
        #expect(report["signal"]?.intValue == Int(SIGTRAP))
        #expect(report["signal_name"] == "SIGTRAP")
        #expect(report["exit_code"] == nil)
        #expect(report["reason"] == "crashed")
        #expect(report["said_hello"] == true)
        #expect(report["cef_version"] == "154.0.0")
        #expect(report["fork_api"]?.intValue == 30)
        #expect(report["pid"]?.intValue == 4242)
        #expect(report["log_tail"] == .array(["[FATAL] navigating to <url>"]))
    }

    @Test func aFailedStartReportsItsExitCodeAndReason() throws {
        var record = Self.trapped
        (record.signal, record.exitCode, record.reason, record.saidHello) = (nil, 65, .launchFailed, false)
        record.startFailure = "could not start (exit 65): the Chromium framework did not load"
        let report = try #require(JSONValue(foundation: Self.writer().report(for: record))?.objectValue)
        #expect(report["signal"] == nil && report["signal_name"] == nil)
        #expect(report["exit_code"]?.intValue == 65)
        #expect(report["reason"] == "launchFailed")
        #expect(report["start_failure"] == "could not start (exit 65): the Chromium framework did not load")
    }

    @Test func eachHostCrashWritesOneReportOffTheMainThread() throws {
        let writer = Self.writer()
        defer { try? FileManager.default.removeItem(at: writer.directory) }
        let work = BackgroundWork(label: "test.chromium-host-crash-report")
        let supervisor = ChromiumHostSupervisor(work: work, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        AppRunMarker.reportHostCrashes(of: supervisor, writer: writer, work: work)
        let report = try #require(supervisor.onHostCrash, "the App does not follow the supervisor's crash records")

        report(Self.trapped)

        let end = Date(timeIntervalSinceNow: 10)
        var files: [String] = []
        while files.isEmpty, Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            files = (try? FileManager.default.contentsOfDirectory(atPath: writer.directory.path)) ?? []
        }
        try #require(files.count == 1)
        #expect(files[0].hasPrefix("com.cmuxterm.app.test-chromium-host-"))
        let data = try Data(contentsOf: writer.directory.appending(path: files[0]))
        let written = try JSONValue.parse(data)
        #expect(written == JSONValue(foundation: writer.report(for: Self.trapped)))
    }
}
#endif
