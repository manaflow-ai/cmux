@testable import CmuxNextApp
import CmuxNextCrashReporting
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The crash keys reach the next launch: a crash with the run marker live writes the keys
/// of that moment into `run.crashkeys` from the crash path, and the next launch reads them back scrubbed.
struct CrashKeysRecordTests {
    @Test func aCrashWritesTheRunningActionAndHungThreadsForTheNextLaunch() async throws {
        let directory = CrashChild.directory("crash-keys", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .failure) {
            await CrashKeysChild.crashInsideAnAction()
        }
        let text = try String(contentsOf: directory.appending(path: "run.crashkeys"), encoding: .utf8)
        let keys = try #require(CrashKeys(record: text), "run.crashkeys holds no record: \(text)")
        #expect(keys.snapshot.actionID == CrashKeySlots.stableKey("workspace.new"), "the record names the running action")
        #expect(keys.snapshot.daemonEpoch == 7)
        #expect(keys.snapshot.hungThreadCount == 1)
        #expect(keys.snapshot.hungThread(at: 0)?.kind == 2)
        #expect(!text.contains("4242"), "a thread port never leaves the process: \(text)")
    }

    /// The crash path's block exists before any crash handler that reads it is installed, also when the run
    /// marker's `run.signal` does not open: the uncaught-exception handler is installed by then, and the block was
    /// made only after that open, so the first write moved into `attachCrashKeys`, after the handlers.
    @Test func theCrashKeysBlockExistsWhenTheSignalFileDoesNotOpen() async {
        let directory = CrashChild.directory("crash-keys-no-signal", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .success) {
            await CrashKeysChild.markRunWithNoSignalFile()
        }
    }

    @Test func aRecordReadBackKeepsOnlyWhatTheCrashPathWrites() throws {
        let planted = "crash_keys action_id=12 path=/Users/someone/secret pane_kind=0x41 cef_state=-1 "
            + "daemon_epoch=99999999999999999999999 token=abc hung_kind_0=300 hung_kind_1=2\n"
        let keys = try #require(CrashKeys(record: planted))
        #expect(keys.snapshot.actionID == 12)
        #expect(keys.snapshot.paneKind == 0)
        #expect(keys.snapshot.cefState == 0)
        #expect(keys.snapshot.daemonEpoch == 0)
        #expect(keys.snapshot.hungThreadCount == 1)
        let values = keys.tags.values.joined(separator: " ")
        #expect(!values.contains("secret") && !values.contains("abc"), "\(keys.tags)")
        #expect(CrashKeys(record: "not a record") == nil)
    }

    /// The next launch puts the previous run's keys into that run's app report and its GitHub issue text,
    /// scrubbed: only the names and numbers the crash path writes.
    @MainActor
    @Test func thePreviousRunsKeysReachItsReportAndIssue() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "crash-keys-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let planted = directory.appending(path: "run.crashkeys")
        try "crash_keys action_id=255 pane_kind=1 daemon_epoch=4 hung_threads=1 hung_kind_0=3 path=/Users/someone\n"
            .write(to: planted, atomically: true, encoding: .utf8)
        let keys = try #require(AppRunMarker.readCrashKeys(planted))
        let previous = PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: false,
                                   survived: true, signal: SIGSEGV, quitting: false)
        let service = CrashRecoveryService(bundleID: "com.cmuxterm.test.crashkeys", runMarker: nil,
                                           work: BackgroundWork(label: "test.crash-keys"), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let tags = try #require(service.appReport(previous, crashKeys: keys)["crash_keys"] as? [String: String])
        #expect(tags["crash_key.action_id"] == "ff")
        #expect(tags["crash_key.pane_kind"] == "terminal")
        #expect(tags["crash_key.daemon_epoch"] == "4")
        #expect(tags["crash_key.hung_thread_kinds"] == "lane")
        #expect(service.appReport(previous)["crash_keys"] == nil, "a run with no record has no keys")
        let issue = CrashIssueReport(previous: previous, version: "1", bundleID: "b", crashKeys: keys)
        #expect(issue.body.contains("- Crash keys: crash_key.action_id=ff crash_key.daemon_epoch=4"), "\(issue.body)")
        #expect(!issue.body.contains("/Users/someone"))
    }

    @Test func theWrittenLineRoundTripsAndFitsItsBuffer() throws {
        let slots = CrashKeySlots()
        slots.set(.actionID, .max)
        slots.set(.paneKind, .max)
        slots.set(.cefState, .max)
        slots.set(.daemonEpoch, .max)
        for port in 1...UInt32(CrashKeySlots.hungThreadCapacity) { slots.noteHung(CrashKeySlots.HungThread(port: port, kind: .max)) }
        let keys = CrashKeys(slots.snapshot())
        var bytes = [UInt8](repeating: 0, count: CrashKeys.maxRecordBytes)
        let count = bytes.withUnsafeMutableBytes { keys.write(into: $0) }
        #expect(count < CrashKeys.maxRecordBytes)
        #expect(bytes[count - 1] == 0x0A)
        let back = try #require(CrashKeys(record: String(decoding: bytes[..<count], as: UTF8.self)))
        #expect(back.snapshot.actionID == .max)
        #expect(back.snapshot.daemonEpoch == .max)
        #expect(back.snapshot.hungThreadCount == CrashKeySlots.hungThreadCapacity)
    }
}

/// The exit-test child: the app's launch order (the run marker, then the crash keys attached), an action run
/// with a hung thread named, and a bad memory access inside it.
enum CrashKeysChild {
    @MainActor
    static func crashInsideAnAction() async {
        let marker = await CrashChild.markRun("crash-keys")
        let slots = CrashKeySlots()
        CrashReporter.attachCrashKeys(slots)
        slots.set(.daemonEpoch, 7)
        slots.noteHung(CrashKeySlots.HungThread(port: 4242, kind: 2))
        slots.withKey(.actionID, CrashKeySlots.stableKey("workspace.new")) {
            CrashChild.badAccess()
        }
        withExtendedLifetime(marker) {}
    }

    /// The run marker's start with this run's signal file (its spare name) a folder, so its open fails and the start
    /// returns there; exits 0 when the crash keys' block exists after it, 1 when it does not, 2 when it existed before.
    @MainActor
    static func markRunWithNoSignalFile() async {
        let directory = CrashChild.directory("crash-keys-no-signal", parent: getppid())
        if CrashReporter.crashKeysBlockIsPrepared { exit(2) }
        try? FileManager.default.createDirectory(at: directory.appending(path: AppRunMarker.spareSignalName, directoryHint: .isDirectory),
                                                 withIntermediateDirectories: true)
        let marker = await CrashChild.mark(directory)
        let prepared = CrashReporter.crashKeysBlockIsPrepared
        withExtendedLifetime(marker) {}
        exit(prepared ? 0 : 1)
    }
}
