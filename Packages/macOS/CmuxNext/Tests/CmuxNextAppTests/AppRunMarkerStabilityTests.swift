@testable import CmuxNextApp
import CmuxNextCrashReporting
import Darwin
import Foundation
import Testing

/// The launch's `stability.unclean_exit` kind (p09-observability task 109): a run killed while its main thread hung
/// (its fatal-hang record still on disk) is a fatal hang, an end in an earlier boot is a system shutdown and never a
/// crash.
struct AppRunMarkerStabilityTests {
    private static let thisBoot = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
    private static let earlierBoot = "ffeeddccbbaa99887766554433221100"
    private static let launched = Date(timeIntervalSince1970: 1_790_000_000)

    private static func run(boot: String?, signal: Int32? = nil, quitting: Bool = false) -> PreviousRun {
        PreviousRun(pid: 4242, launched: launched, recovery: false, survived: true, signal: signal, quitting: quitting,
                    bootSession: boot)
    }

    @Test func aHungRunKilledInThisBootIsAFatalHang() {
        #expect(Self.run(boot: Self.thisBoot).uncleanExit(bootSession: Self.thisBoot, hung: true) == .fatalHang)
        #expect(Self.run(boot: Self.thisBoot).uncleanExit(bootSession: Self.thisBoot, hung: false) == .killed)
    }

    @Test func anotherBootIsNeverACrashOrAHang() {
        for hung in [false, true] {
            #expect(Self.run(boot: Self.earlierBoot).uncleanExit(bootSession: Self.thisBoot, hung: hung) == .systemShutdown)
        }
        #expect(Self.run(boot: Self.thisBoot, signal: SIGSEGV).uncleanExit(bootSession: Self.thisBoot, hung: true) == .crash)
        #expect(Self.run(boot: Self.thisBoot, quitting: true).uncleanExit(bootSession: Self.thisBoot, hung: true) == nil)
    }

    @Test func theLaunchReadFindsTheHungRunsRecord() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stability-marker-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = Self.run(boot: Self.thisBoot)
        let record = { (startedAt: Date) in
            FatalHangRecord(pid: previous.pid, startedAt: startedAt, startUptimeNanos: 7_000_000_000, elapsedNanos: 3_000_000_000,
                            addresses: [], phase: nil, attribution: nil, release: "test", dist: "1")
        }
        let file = folder.appending(path: FatalHangRecorder.fileName(pid: previous.pid))
        let run = (pid: previous.pid, launched: previous.launched)
        #expect(!FatalHangRecorder.hasRecord(in: folder, of: run), "no record, no hang")

        try JSONEncoder().encode(record(Self.launched.addingTimeInterval(-3_600))).write(to: file)
        #expect(!FatalHangRecorder.hasRecord(in: folder, of: run), "an older run's record under a reused pid")

        try JSONEncoder().encode(record(Self.launched.addingTimeInterval(30))).write(to: file)
        #expect(FatalHangRecorder.hasRecord(in: folder, of: run))
        #expect(FileManager.default.fileExists(atPath: file.path), "the check only reads: the report takes the record later")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(previous).write(to: folder.appending(path: "run.json"))
        let launch = AppRunMarker.prepareLaunch(directory: folder, now: Date(), bootSession: Self.thisBoot,
                                                gate: LaunchSafeMode.Gate(fixed: .noStreak))
        if launch.signalDescriptor >= 0 { close(launch.signalDescriptor) }
        if launch.keysDescriptor >= 0 { close(launch.keysDescriptor) }
        #expect(launch.previousExit == .fatalHang)

        try encoder.encode(Self.run(boot: Self.thisBoot, signal: nil, quitting: true)).write(to: folder.appending(path: "run.json"))
        let quit = AppRunMarker.prepareLaunch(directory: folder, now: Date(), bootSession: Self.thisBoot,
                                              gate: LaunchSafeMode.Gate(fixed: .noStreak))
        if quit.signalDescriptor >= 0 { close(quit.signalDescriptor) }
        if quit.keysDescriptor >= 0 { close(quit.keysDescriptor) }
        #expect(quit.previousExit == nil, "a quit that hung on its way out is no unclean exit")
    }
}
