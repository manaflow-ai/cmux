@testable import CmuxNextApp
import Foundation
import Testing

/// The "cmux restarted after a problem" notice is for real crashes: a run
/// whose fatal signal handler wrote its signal, or that ended on an uncaught
/// exception. A run that ended with no handler running (`kill -9` of the
/// app, jetsam, power loss) restores the same way, without the notice.
struct CrashNoticeTests {
    @Test func aKilledRunRestoresWithoutTheCrashNotice() throws {
        let previous = try Self.previous(signal: nil)
        #expect(!LaunchRecovery.decide(previous: previous).isRestart, "a kill -9 of the app showed the crash notice")
    }

    @Test func aRunThatCrashedShowsTheNotice() throws {
        #expect(LaunchRecovery.decide(previous: try Self.previous(signal: "\(SIGSEGV)\n")).isRestart)
        #expect(LaunchRecovery.decide(previous: try Self.previous(signal: "\(SIGABRT)\n")).isRestart)
    }

    @Test func anUncaughtExceptionShowsTheNotice() throws {
        let exception = RecordedException(name: "NSInvalidArgumentException", reason: "boom", frames: [])
        let previous = try Self.previous(signal: nil, exception: exception)
        #expect(previous?.exception == exception)
        #expect(LaunchRecovery.decide(previous: previous).isRestart)
    }

    /// Force Quit of an app hung at restore records no signal. A second
    /// quick kill is a safe restart (`crashedPages` holds the pages that run
    /// started), so a page that hangs the app cannot loop.
    @Test func aRestoreThatHangsTwiceSkipsBrowserPages() throws {
        let first = try Self.previous(signal: nil, survived: false)
        #expect(!LaunchRecovery.decide(previous: first).isRestart)
        #expect(LaunchRecovery.watchesForLoop(previous: first))
        let second = try Self.previous(signal: nil, recovery: true, survived: false)
        #expect(LaunchRecovery.decide(previous: second).isSafeRestart)
        #expect(!LaunchRecovery.watchesForLoop(previous: try Self.previous(signal: nil)))
    }

    /// A safe restart holds only the pages the quick-ending run started; a plain restart holds none.
    @Test func aSafeRestartHoldsOnlyThePagesTheEndedRunStarted() throws {
        let safe = try Self.previous(signal: "\(SIGSEGV)\n", recovery: true, survived: false, startedPages: ["tab-a"])
        #expect(LaunchRecovery.decide(previous: safe).crashedPages == ["tab-a"])
        let plain = try Self.previous(signal: "\(SIGSEGV)\n", startedPages: ["tab-a"])
        #expect(LaunchRecovery.decide(previous: plain).crashedPages.isEmpty)
        let old = try Self.previous(signal: "\(SIGSEGV)\n", recovery: true, survived: false)
        #expect(LaunchRecovery.decide(previous: old).crashedPages.isEmpty, "a marker without started pages holds none")
    }

    /// What the next launch reads from the files a previous run left:
    /// `run.json` still there (no quit removed it), `run.signal` and
    /// `run.exception`.
    private static func previous(signal: String?, recovery: Bool = false, survived: Bool = true,
                                 exception: RecordedException? = nil, startedPages: [String]? = nil) throws -> PreviousRun? {
        let directory = FileManager.default.temporaryDirectory.appending(path: "crash-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var run = PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: recovery,
                              survived: survived, signal: nil, quitting: false)
        run.startedPages = startedPages
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(run).write(to: directory.appending(path: "run.json"))
        try (signal ?? "").write(to: directory.appending(path: "run.signal"), atomically: true, encoding: .utf8)
        if let exception {
            try JSONEncoder().encode(exception).write(to: directory.appending(path: "run.exception"))
        }
        return AppRunMarker.readPrevious(marker: directory.appending(path: "run.json"),
                                         signal: directory.appending(path: "run.signal"),
                                         exception: directory.appending(path: "run.exception"))
    }
}
