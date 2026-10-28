@testable import CmuxNextApp
import Darwin
import Foundation
import Testing

/// The previous run whose fatal-hang record the next launch reports (`AppRunMarker.previousUnreported`)
/// is one that no crash report covers: a killed run or one the Mac's shutdown ended, never a quit or a crash, which
/// would report the same end twice.
struct AppRunMarkerUnreportedRunTests {
    private static let thisBoot = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
    private static let earlierBoot = "ffeeddccbbaa99887766554433221100"

    @Test func aKilledRunIsUnreported() throws {
        let run = try Self.previous()
        #expect(run.unreported(bootSession: Self.thisBoot) == run)
    }

    @Test func aRunTheShutdownEndedIsUnreported() throws {
        let run = try Self.previous(boot: Self.earlierBoot)
        #expect(run.unreported(bootSession: Self.thisBoot) == run)
    }

    @Test func aQuitIsNotReported() throws {
        #expect(try Self.previous(quitting: true).unreported(bootSession: Self.thisBoot) == nil, "a quit that had begun")
        #expect(try Self.previous(signal: "\(SIGTERM)\n").unreported(bootSession: Self.thisBoot) == nil, "a requested-quit signal")
    }

    @Test func aCrashIsNotReportedTwice() throws {
        #expect(try Self.previous(signal: "\(SIGSEGV)\n").unreported(bootSession: Self.thisBoot) == nil)
        #expect(try Self.previous(boot: Self.earlierBoot, signal: "\(SIGABRT)\n").unreported(bootSession: Self.thisBoot) == nil,
                "a crash before a restart is still a crash")
    }

    /// What the next launch reads from the `run.json` and `run.signal` a previous run left.
    private static func previous(boot: String = AppRunMarkerUnreportedRunTests.thisBoot, quitting: Bool = false, signal: String? = nil) throws -> PreviousRun {
        let directory = FileManager.default.temporaryDirectory.appending(path: "unreported-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: false,
                              survived: true, signal: nil, quitting: quitting, bootSession: boot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(run).write(to: directory.appending(path: "run.json"))
        try (signal ?? "").write(to: directory.appending(path: "run.signal"), atomically: true, encoding: .utf8)
        return try #require(AppRunMarker.readPrevious(marker: directory.appending(path: "run.json"),
                                                      signal: directory.appending(path: "run.signal")))
    }
}
