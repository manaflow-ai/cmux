import Foundation
import Testing
@testable import CmuxNextApp

/// Whole-app crash recovery: how a launch follows the previous run, and
/// the run marker on disk.
@MainActor
@Suite struct LaunchRecoveryTests {
    private func run(recovery: Bool = false, survived: Bool = false, signal: Int32? = nil) -> PreviousRun {
        PreviousRun(pid: 42, launched: Date(timeIntervalSince1970: 1_000), recovery: recovery, survived: survived, signal: signal)
    }

    @Test func noMarkerIsAClean() {
        #expect(LaunchRecovery.decide(previous: nil) == .clean)
    }

    /// SIGTERM, SIGINT and SIGHUP ask the app to quit (`kill`, Ctrl-C in
    /// the launching terminal, that terminal closing): never a restart.
    @Test(arguments: [SIGTERM, SIGINT, SIGHUP])
    func aRequestedQuitSignalIsClean(_ signal: Int32) {
        #expect(LaunchRecovery.decide(previous: run(signal: signal)) == .clean)
    }

    /// A fault, abort() or a bad system call is a crash: the notice shows.
    @Test(arguments: [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS])
    func aFatalSignalIsARestart(_ signal: Int32) {
        #expect(LaunchRecovery.decide(previous: run(signal: signal)) == .restarted(run(signal: signal)))
    }

    @Test func aCrashRestoresEverything() {
        let decision = LaunchRecovery.decide(previous: run(signal: SIGSEGV))
        #expect(decision == .restarted(run(signal: SIGSEGV)))
        #expect(decision.isRestart)
        #expect(!decision.skipsBrowserPages)
    }

    @Test func anEndWithNoHandlerStillCounts() {
        // SIGKILL or jetsam: no signal was written.
        #expect(LaunchRecovery.decide(previous: run()).isRestart)
    }

    @Test func aQuickCrashAfterARestartSkipsBrowserPages() {
        let decision = LaunchRecovery.decide(previous: run(recovery: true, survived: false, signal: SIGTRAP))
        #expect(decision.skipsBrowserPages)
    }

    @Test func aRestartThatLivedPastTheWindowRestoresAgain() {
        let decision = LaunchRecovery.decide(previous: run(recovery: true, survived: true, signal: SIGSEGV))
        #expect(decision.isRestart)
        #expect(!decision.skipsBrowserPages)
    }

    @Test func markerRoundTripsAndACleanExitRemovesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = AppRunMarker(directory: folder)
        #expect(first.recovery == .clean)
        // No clean exit: the next launch is a restart.
        let second = AppRunMarker(directory: folder)
        #expect(second.recovery.isRestart)
        #expect(second.recovery.previous?.pid == getpid())
        // The restart itself ends quickly: safe restart.
        let third = AppRunMarker(directory: folder)
        #expect(third.recovery.skipsBrowserPages)
        third.markCleanExit()
        #expect(AppRunMarker(directory: folder).recovery == .clean)
    }

    @Test func aWrittenSignalIsRead() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cmux-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = AppRunMarker(directory: folder)
        try Data("11\n".utf8).write(to: folder.appending(path: "run.signal"))
        let next = AppRunMarker(directory: folder)
        #expect(next.recovery.previous?.signal == SIGSEGV)
    }
}
