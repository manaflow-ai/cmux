@testable import CmuxNextApp
import Foundation
import Testing

/// The "cmux restarted after a problem" notice is for real crashes: a run
/// whose fatal signal handler wrote its signal, or that ended on an uncaught
/// exception. A run that ended with no handler running (`kill -9` of the
/// app, jetsam, power loss) restores the same way, without the notice.
struct CrashNoticeTests {
    @Test func aKilledRunRestoresWithoutTheCrashNotice() throws {
        let recovery = try Self.recovery(signal: nil)
        #expect(!recovery.isRestart, "a kill -9 of the app showed the crash notice")
    }

    @Test func aRunThatCrashedShowsTheNotice() throws {
        #expect(try Self.recovery(signal: "\(SIGSEGV)\n").isRestart)
        #expect(try Self.recovery(signal: "\(SIGABRT)\n").isRestart)
    }

    /// The decision the next launch makes from the files a previous run
    /// left: `run.json` still there (no quit removed it) and `run.signal`.
    private static func recovery(signal: String?) throws -> LaunchRecovery {
        let directory = FileManager.default.temporaryDirectory.appending(path: "crash-notice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: false,
                              survived: true, signal: nil, quitting: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(run).write(to: directory.appending(path: "run.json"))
        try (signal ?? "").write(to: directory.appending(path: "run.signal"), atomically: true, encoding: .utf8)
        let previous = AppRunMarker.readPrevious(marker: directory.appending(path: "run.json"),
                                                 signal: directory.appending(path: "run.signal"),
                                                 exception: directory.appending(path: "run.exception"))
        return LaunchRecovery.decide(previous: previous)
    }
}
