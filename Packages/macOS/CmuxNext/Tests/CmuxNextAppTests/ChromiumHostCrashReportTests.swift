#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
import CmuxNextSettings
import CmuxNextWakeups
import Darwin
import Foundation
import os
import Testing

/// An end of the Chromium Host becomes one crash report in the report folder and one `debug.crashes`
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

    /// The acceptance of p01-process-085: after a SIGTRAP, `debug.crashes` lists the host's end in `chromium_host` with
    /// its signal, through the App's own path (the source's supervisor, cast as `DebugCrashes` casts it).
    @Test func debugCrashesListsATrappedHostWithItsSignal() async throws {
        let spawner = EndingSpawner()
        let supervisor = ChromiumHostSupervisor(spawner: spawner)
        _ = try await supervisor.attachment()
        supervisor.hostSaidHello()
        supervisor.hostRuns(forkAPI: 30)
        spawner.end(ChromiumHostExit(signal: SIGTRAP, status: nil), logTail: ["[FATAL] Check failed: <url>"])

        let report = try #require(DebugCrashes.report(crash: Self.crashRecovery(), chromium: BrowserCrashLog(),
                                                      hostSupervisor: supervisor).objectValue)
        #expect(report["chromium_host_total"]?.intValue == 1)
        let rows = try #require(report["chromium_host"]?.arrayValue)
        try #require(rows.count == 1)
        let row = try #require(rows[0].objectValue)
        #expect(row["signal"]?.intValue == Int(SIGTRAP))
        #expect(row["signal_name"] == "SIGTRAP")
        #expect(row["reason"] == "crashed")
        #expect(row["pid"]?.intValue == Int(EndingSpawner.pid))
        #expect(row["fork_api"]?.intValue == 30)
        #expect(row["cef_version"] == "154.0.0")
        #expect(row["log_tail"] == .array(["[FATAL] Check failed: <url>"]))
    }

    /// In process (no host supervisor) the report has no `chromium_host` rows.
    @Test func debugCrashesHasNoHostRowsInProcess() throws {
        let report = try #require(DebugCrashes.report(crash: Self.crashRecovery(), chromium: BrowserCrashLog(),
                                                      hostSupervisor: nil).objectValue)
        #expect(report["chromium_host"] == nil)
        #expect(report["chromium_host_total"] == nil)
        #expect(report["chromium_total"]?.intValue == 0)
    }

    private static func crashRecovery() -> CrashRecoveryService {
        CrashRecoveryService(bundleID: nil, runMarker: nil, work: BackgroundWork(label: "test.debug-crashes"),
                             mainWork: MainWorkScheduler(budget: MainFrameBudget()))
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

/// A host that is never a process: its spawn hands out a wire with no descriptor, and the test ends it with
/// ``end(_:logTail:)`` as the supervisor's exit watch would.
private nonisolated final class EndingSpawner: ChromiumHostSpawning {
    static let pid: pid_t = 4243
    private let watched = OSAllocatedUnfairLock<(@MainActor @Sendable (ChromiumHostExit, [String]) -> Void)?>(initialState: nil)

    func spawn() async throws(ChromiumHostAttachError) -> ChromiumHostSpawn {
        ChromiumHostSpawn(pid: Self.pid,
                          attachment: ChromiumHostAttachment(controlFD: -1, remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"),
                                                             frameworkLocales: []),
                          logFile: nil, cefVersion: "154.0.0")
    }

    func watchExit(of pid: pid_t, log: URL?, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit, [String]) -> Void) {
        watched.withLock { $0 = ended }
    }

    func reap(_ pid: pid_t) {}

    func kill(_ pid: pid_t) {}

    @MainActor func end(_ exit: ChromiumHostExit, logTail: [String]) {
        watched.withLock { $0 }?(exit, logTail)
    }
}
#endif
