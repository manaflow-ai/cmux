@testable import CmuxNextApp
import CmuxNextCrashReporting
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// p10-stability-203: the next launch turns the run marker the previous run left into its exit outcome, the
/// clean exit beacon's value (components/metrics/clean_exit_beacon.cc). A run killed with SIGKILL, which no
/// handler sees, is `unclean-no-report`; a run that reached its normal quit (`markCleanExit`) is `clean`, as is a
/// quit someone asked for; a handler's record is a crash in any boot; no handler and another boot is a system
/// shutdown; a first launch has no outcome.
struct UncleanExitBeaconTests {
    private static let thisBoot = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
    private static let earlierBoot = "ffeeddccbbaa99887766554433221100"

    @Test func aSIGKILLedRunIsUncleanNoReportAtTheNextLaunch() async throws {
        let directory = CrashChild.directory("sigkill", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .signal(SIGKILL)) {
            await UncleanExitChild.killed()
        }
        // The next launch's marker read, in this boot.
        let launch = AppRunMarker.prepareLaunch(directory: directory, now: Date(), bootSession: AppRunMarker.currentBootSession())
        for descriptor in [launch.signalDescriptor, launch.keysDescriptor] where descriptor >= 0 { close(descriptor) }
        let report = try #require(CrashRecoveryService.exitReport(of: launch), "the killed child left no run.json")
        #expect(report.outcome == .uncleanNoReport)
        #expect(report.signal == nil)
    }

    /// The clean record a normal quit leaves: before it, `RunMarkerFile.close` removed `run.json`, so the next
    /// launch read a quit as a first launch and never sent `clean`.
    @Test func aRunThatQuitNormallyIsCleanAtTheNextLaunch() async throws {
        let directory = CrashChild.directory("clean-quit", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .success) {
            await UncleanExitChild.quit()
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "run.signal").path), "the quit removes run.signal")
        let launch = AppRunMarker.prepareLaunch(directory: directory, now: Date(), bootSession: AppRunMarker.currentBootSession())
        for descriptor in [launch.signalDescriptor, launch.keysDescriptor] where descriptor >= 0 { close(descriptor) }
        let report = try #require(CrashRecoveryService.exitReport(of: launch), "the quit left no record: it reads as a first launch")
        #expect(report.outcome == .clean)
        #expect(report.signal == nil)
        #expect(launch.recovery == .clean, "a quit is no restart")
        #expect(launch.previousExit == nil, "a quit is no unclean exit")
        #expect(launch.previousUnreported == nil)
        #expect(!LaunchRecovery.countsTowardCrashStreak(previous: launch.previous))
        #expect(!launch.marker.recovery, "the run after a quit watches for no restart loop")
    }

    @Test func aQuitsRecordReplacesTheMarkerAndAFailedWriteRemovesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "beacon-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "run.json"), signal = directory.appending(path: "run.signal")
        try Data("live".utf8).write(to: marker)
        try Data().write(to: signal)
        RunMarkerFile(url: marker, signalURL: signal).close(leaving: Data("quit".utf8))
        #expect(try Data(contentsOf: marker) == Data("quit".utf8))
        #expect(!FileManager.default.fileExists(atPath: signal.path))

        struct Refused: Error {}
        try Data().write(to: signal)
        RunMarkerFile(url: marker, signalURL: signal, writer: { _, _ in throw Refused() }).close(leaving: Data("quit".utf8))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "a live record never stays after a quit")
        #expect(!FileManager.default.fileExists(atPath: signal.path))
    }

    @Test func aFirstLaunchHasNoOutcome() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "beacon-first-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let launch = AppRunMarker.prepareLaunch(directory: directory, now: Date(), bootSession: Self.thisBoot)
        for descriptor in [launch.signalDescriptor, launch.keysDescriptor] where descriptor >= 0 { close(descriptor) }
        #expect(CrashRecoveryService.exitReport(of: launch) == nil)
    }

    @Test func aQuitIsClean() {
        #expect(Self.run(quitting: true).exitReport(bootSession: Self.thisBoot, crashKeys: nil).outcome == .clean)
        #expect(Self.run(signal: SIGTERM).exitReport(bootSession: Self.thisBoot, crashKeys: nil).outcome == .clean,
                "a requested-quit signal")
    }

    @Test func aHandlersRecordIsACrashInAnyBoot() {
        let segv = Self.run(boot: Self.earlierBoot, signal: SIGSEGV).exitReport(bootSession: Self.thisBoot, crashKeys: nil)
        #expect(segv.outcome == .signal)
        #expect(segv.signal == SIGSEGV)
        var thrown = Self.run(signal: SIGABRT)
        thrown.exception = RecordedException(name: "NSRangeException", reason: "index 3 beyond bounds", frames: [])
        let exception = thrown.exitReport(bootSession: Self.thisBoot, crashKeys: nil)
        #expect(exception.outcome == .exception, "the exception, not its abort, is the cause")
        #expect(exception.signal == nil)
    }

    @Test func aCrashPathWithNoRecordIsCrashCaught() {
        let keys = CrashKeys(CrashKeySlots().snapshot())
        #expect(Self.run().exitReport(bootSession: Self.thisBoot, crashKeys: keys).outcome == .crashCaught)
    }

    @Test func noHandlerAndAnotherBootIsASystemShutdown() {
        #expect(Self.run(boot: Self.earlierBoot).exitReport(bootSession: Self.thisBoot, crashKeys: nil).outcome == .systemShutdown)
        #expect(Self.run(boot: Self.earlierBoot).exitReport(bootSession: nil, crashKeys: nil).outcome == .uncleanNoReport,
                "an unknown boot is this boot")
    }

    @Test func theReportKeepsTheRunsFlags() {
        var run = Self.run()
        run.survived = false
        run.recovery = true
        let report = run.exitReport(bootSession: Self.thisBoot, crashKeys: nil)
        #expect(!report.survived)
        #expect(report.followedRestart)
    }

    private static func run(boot: String = UncleanExitBeaconTests.thisBoot, quitting: Bool = false, signal: Int32? = nil) -> PreviousRun {
        PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: false, survived: true,
                    signal: signal, quitting: quitting, bootSession: boot)
    }
}

/// What the exit-test children run: the app's launch with the run marker live, then a SIGKILL, which no handler
/// sees, or the app's normal quit.
enum UncleanExitChild {
    @MainActor
    static func quit() async {
        let marker = await CrashChild.markRun("clean-quit")
        marker.markCleanExit()
        exit(0)
    }

    @MainActor
    static func killed() async {
        let marker = await CrashChild.markRun("sigkill")
        _ = kill(getpid(), SIGKILL)
        withExtendedLifetime(marker) {}
    }
}
