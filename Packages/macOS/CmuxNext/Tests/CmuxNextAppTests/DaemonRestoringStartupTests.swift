import AppKit
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonRecovery
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Darwin
import Foundation
import Testing
import CmuxNextWakeupsTestSupport
@testable import CmuxNextApp

/// The incident of 2026-11-02 at the service's boundary (plans/cmux-next/long-jobs-DESIGN.md): the owner
/// parked every connection during a 303 s output cleanup. The remembered socket's `identify` timed out,
/// the startup deadline passed, and the window said "cmux could not start its background service. Quit and
/// reopen cmux", which restarted the cleanup. Here the app's real startup path (prestart on the launcher,
/// `DaemonService.start(launch:)`) meets a live parked socket with the owner's `long-jobs.json`, then a
/// stand-in `server ensure` that reports restore progress with the job and never finishes.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DaemonRestoringStartupTests {
    private let directory = URL(fileURLWithPath: "/tmp/cnrs-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
    private static let session = "cmux-app-restoring"

    private static func job(done: Int, total: Int) -> String {
        #"{"id":"output_cleanup:1","kind":"registry.output_cleanup","title":"Cleaning up stored terminal output","detail":"segment \#(done) of \#(total)","done":\#(done),"total":\#(total),"unit":"segments","started_ms":1793683713000,"updated_ms":1793683850000,"blocks":["startup","quit"],"cancellable":false}"#
    }

    /// A listening socket that never accepts (the parked owner).
    private func parkedSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() where index < buffer.count - 1 { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    @Test func aParkedLiveOwnerReadsRestoringWithItsJobPastTheDeadline() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("o.sock").path
        let listener = try parkedSocket(at: socketPath)
        defer { close(listener) }
        let state = directory.appendingPathComponent("state", isDirectory: true)
        let sessionDirectory = state.appendingPathComponent(OwnerJobsFile.storageComponent(session: Self.session), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let now = Int64(exactly: (Date().timeIntervalSince1970 * 1000).rounded()) ?? 0
        try Data(#"{"version":1,"pid":\#(getpid()),"updated_ms":\#(now),"jobs":[\#(Self.job(done: 387, total: 900))]}"#.utf8)
            .write(to: sessionDirectory.appendingPathComponent(OwnerJobsFile.fileName))
        // `server ensure` reports the job at 60% and then waits on a pipe nobody writes (the owner still restoring).
        let never = directory.appendingPathComponent("never")
        guard mkfifo(never.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let script = """
        #!/bin/sh
        case " $* " in
        *" server status "*) exit 1 ;;
        *" server ensure "*)
            printf '%s\\n' '{"progress":"restoring","session":"\(Self.session)","pid":4242,"waited_ms":5000,"jobs":[\(Self.job(done: 600, total: 1000))]}'
            read -r _ < '\(never.path)'
            exit 3 ;;
        esac
        exit 64
        """
        let binary = directory.appendingPathComponent("cmux-tui")
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        // The launcher's clock (the ensure's idle bound, `server status`) never moves: the stand-in's ensure waits.
        let launcher = DaemonLauncher(configuration: .init(binary: binary, session: Self.session, stateDirectory: state,
                                                           rememberedSocket: socketPath, binaryIsBundled: true),
                                      environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"] },
                                      clock: ManualClock())
        let daemon = DaemonService()
        // The startup deadline (10 s) and the retry pacer run on a manual clock: the parked identify is judged first,
        // then the test moves time past the deadline, which also ends the retry's backoff so it runs `server ensure`.
        let clock = ManualClock()
        daemon.startupClock = clock
        let prestart = DaemonPrestart(launcher: launcher, configuration: launcher.localOwnerHooks(
            DaemonConnection.Configuration(requiredCapabilities: [], requestTimeout: .milliseconds(500), terminalEnvironment: nil)))
        daemon.start(launch: AppEnvironment.current([:]).launch, terminalEnvironment: [:], terminalEnvironmentProvider: { [:] },
                     prestart: prestart)

        // First the parked identify: the status file's job (43%), long before the deadline.
        for await startup in ObservationStream({ daemon.startup }) {
            #expect(!startup.isUnavailable, "a live restoring owner read as unavailable: \(startup)")
            if startup.isRestoring { break }
        }
        #expect(daemon.startup.restoringJobs.first?.percent == 43, "the parked identify did not read the owner's status file")
        // The deadline and the retry's backoff are both asleep: one step past both.
        try await clock.waitForSleepers(2)
        clock.advance(by: .seconds(11))
        for await passed in ObservationStream({ daemon.startupDeadlinePassed }) where passed { break }
        #expect(daemon.startup.isRestoring, "past the startup deadline the restoring owner read as \(daemon.startup)")
        // Then the retry's `server ensure` reports the job at 60%.
        for await startup in ObservationStream({ daemon.startup }) {
            #expect(!startup.isUnavailable, "past the deadline the restoring owner read as unavailable: \(startup)")
            if startup.restoringJobs.first?.percent == 60 { break }
        }
        #expect(daemon.startup.isRestoring)
        #expect(daemon.startup.restoringJobs.map(\.kind) == [LongJob.outputCleanupKind])
        #expect(daemon.store.connectionState == .connecting, "the store read the restoring owner as failed")
        #expect(daemon.jobs.first?.machine == daemon.machineID)

        let reason = try #require(daemon.notConnectedReason)
        #expect(reason == RefusalStrings.restoring(daemon.startup.restoringJobs))
        #expect(reason.contains(try #require(daemon.startup.restoringJobs.first?.percentText)))
        #expect(!reason.contains("Quit and reopen"), "the refusal told the person to quit")
        #expect(daemon.missingCapabilityMessage(DaemonCapability.longJobs.rawValue) == reason)
        #expect(!RefusalStrings.daemonUnavailable.lowercased().contains("quit"))

        // The window's connecting state: the job, its progress, and to wait.
        let view = DaemonConnectingView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.apply(daemon.startup)
        #expect(view.titleText == daemon.startup.restoringJobs.first?.displayTitle)
        #expect(view.progressShown == 0.6)
        #expect(view.guidanceText == DaemonRecoveryStrings.dontQuit)

        await daemon.shutdownConnectionAndWait()
    }

    /// The Activity indicator: hidden with no job, a glyph while an app job runs (`icon`), the job and its percent
    /// beside it (`labeled`), and hidden again when the job ends.
    @Test func theActivityIndicatorFollowsTheJobsInBothDesigns() throws {
        let jobs = LongJobs()
        let indicator = ActivityIndicatorView(jobs: jobs, labeled: { false }, onVisibilityChange: {})
        #expect(indicator.isHidden)

        let handle = jobs.begin(kind: LongJob.browserImportKind)
        handle.progress(fraction: 0.25)
        indicator.show(jobs.all, labeled: false)
        #expect(!indicator.isHidden)
        #expect(indicator.button.text == nil, "the icon design shows the glyph alone")
        #expect(indicator.width == TitlebarBandButton.side)

        indicator.show(jobs.all, labeled: true)
        let title = try #require(indicator.button.text)
        let job = try #require(jobs.all.first)
        #expect(title.contains(job.displayTitle))
        #expect(title.contains(try #require(job.percentText)))
        #expect(indicator.width > TitlebarBandButton.side)

        handle.end()
        #expect(jobs.all.isEmpty)
        indicator.show(jobs.all, labeled: true)
        #expect(indicator.isHidden)
    }
}
