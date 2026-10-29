@testable import CmuxNextApp
import CmuxNextLaunch
import CmuxNextMetrics
import Foundation
import Testing

/// The run marker's boot-session beacon (task 053): a run that ended with no handler running and a different
/// `kern.bootsessionuuid` at the next launch ended in a system shutdown, never a crash or a restart loop.
struct AppRunMarkerBootSessionTests {
    private static let thisBoot = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
    private static let earlierBoot = "ffeeddccbbaa99887766554433221100"

    @Test func aKilledRunInAnEarlierBootIsASystemShutdown() throws {
        let run = try Self.previous(boot: Self.earlierBoot, survived: false)
        #expect(run.uncleanExit(bootSession: Self.thisBoot) == .systemShutdown)
        let recovered = run.forRecovery(bootSession: Self.thisBoot)
        #expect(!LaunchRecovery.decide(previous: recovered).isRestart)
        #expect(!LaunchRecovery.watchesForLoop(previous: recovered),
                "a power loss within a minute of launch made the next launch watch for a restart loop")
    }

    @Test func aKilledRunInThisBootIsKilled() throws {
        let run = try Self.previous(boot: Self.thisBoot, survived: false)
        #expect(run.uncleanExit(bootSession: Self.thisBoot) == .killed)
        #expect(LaunchRecovery.watchesForLoop(previous: run.forRecovery(bootSession: Self.thisBoot)))
    }

    /// The handler's record says the fault ended the run, whatever happened to the machine after it.
    @Test func aCrashBeforeARestartIsStillACrash() throws {
        let run = try Self.previous(boot: Self.earlierBoot, signal: "\(SIGSEGV)\n")
        #expect(run.uncleanExit(bootSession: Self.thisBoot) == .crash)
        #expect(LaunchRecovery.decide(previous: run.forRecovery(bootSession: Self.thisBoot)).isRestart)
    }

    @Test func aRequestedQuitIsNoUncleanExit() throws {
        let run = try Self.previous(boot: Self.earlierBoot, signal: "\(SIGTERM)\n")
        #expect(run.uncleanExit(bootSession: Self.thisBoot) == nil)
    }

    /// Markers written before the beacon, and a kernel that gives no boot id, keep today's reading.
    @Test func anUnknownBootIsKilled() throws {
        let old = try Self.previous(boot: nil, survived: false)
        #expect(old.uncleanExit(bootSession: Self.thisBoot) == .killed)
        let run = try Self.previous(boot: Self.earlierBoot, survived: false)
        #expect(run.uncleanExit(bootSession: nil) == .killed)
    }

    /// A power loss or a reboot left no daemon to reattach, so its launch keeps the saved terminal frames
    /// and window picture through the cold daemon start; a kill or a crash in this boot left it running, so they go.
    @Test func onlyAnEndInThisBootReattaches() throws {
        let shutdown = try Self.previous(boot: Self.earlierBoot, survived: false).uncleanExit(bootSession: Self.thisBoot)
        #expect(RelaunchReattach.PreviousEnd(shutdown) == .systemShutdown)
        #expect(RelaunchReattach(previousEnd: .init(shutdown), enabled: true).keepsSavedScreens)
        let killed = try Self.previous(boot: Self.thisBoot, survived: false).uncleanExit(bootSession: Self.thisBoot)
        #expect(!RelaunchReattach(previousEnd: .init(killed), enabled: true).keepsSavedScreens)
        let crashed = try Self.previous(boot: Self.earlierBoot, signal: "\(SIGSEGV)\n").uncleanExit(bootSession: Self.thisBoot)
        #expect(RelaunchReattach.PreviousEnd(crashed) == .crashed)
        #expect(RelaunchReattach.PreviousEnd(nil) == .quit)
        #expect(RelaunchReattach.PreviousEnd(.fatalHang) == .killed)
    }

    @Test func theBootIsThirtyTwoHexDigits() {
        let boot = AppRunMarker.currentBootSession()
        #expect(boot?.count == 32)
        #expect(boot?.allSatisfy(\.isHexDigit) == true)
    }

    /// What the next launch reads from the `run.json` and `run.signal` a previous run left.
    private static func previous(boot: String?, survived: Bool = true, signal: String? = nil) throws -> PreviousRun {
        let directory = FileManager.default.temporaryDirectory.appending(path: "boot-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: false,
                              survived: survived, signal: nil, quitting: false, bootSession: boot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(run).write(to: directory.appending(path: "run.json"))
        try (signal ?? "").write(to: directory.appending(path: "run.signal"), atomically: true, encoding: .utf8)
        let read = try #require(AppRunMarker.readPrevious(marker: directory.appending(path: "run.json"),
                                                          signal: directory.appending(path: "run.signal")))
        #expect(read.bootSession == boot, "run.json lost the boot session")
        return read
    }
}
