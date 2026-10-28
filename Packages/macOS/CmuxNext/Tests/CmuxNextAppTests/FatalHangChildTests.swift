@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import Darwin
import Foundation
import Testing

/// The fatal case of the hang matrix: a child process marks its run, starts the main-thread
/// watchdog with the app's fatal-hang recorder, hangs its main thread for 3 s and is killed with SIGKILL (Force Quit,
/// the system's kill of a hung app). The folder it leaves is read as the next launch reads it: a killed run that no
/// crash report covers, and one fatal-hang record with the main thread's stack, taken once.
struct FatalHangChildTests {
    @Test func aRunKilledWhileItHangsLeavesOneFatalHangForTheNextLaunch() async throws {
        let directory = CrashChild.directory("fatal-hang", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .signal(SIGKILL)) {
            await FatalHangChild.hangThenGetKilled()
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.uncleanExit(bootSession: AppRunMarker.currentBootSession()) == .killed)
        let record = try #require(FatalHangRecorder.takePrevious(in: directory, run: (pid: previous.pid, launched: previous.launched)),
                                  "the hung child left no fatal-hang record")
        #expect(record.pid == previous.pid)
        #expect(record.elapsedNanos >= 2_000_000_000)
        #expect(!record.frames.isEmpty, "the record has no main-thread stack")
        #expect(!record.images.isEmpty, "the stack names no image for debug_meta")
        #expect(FatalHangRecorder.takePrevious(in: directory, run: (pid: previous.pid, launched: previous.launched)) == nil,
                "a record is reported once")
    }
}

enum FatalHangChild {
    /// The run marker, then the watchdog and the recorder as the app wires them (WatchdogReporting), then a main
    /// thread that does not answer for 3 s (and until the record is written, at most 20 s), then SIGKILL.
    @MainActor
    static func hangThenGetKilled() async {
        let marker = await CrashChild.markRun("fatal-hang")
        let recorder = FatalHangRecorder(directory: CrashChild.directory("fatal-hang", parent: getppid()), release: "test", dist: "1")
        let written = Written()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false, hangAssertThreshold: nil))
        watchdog.fatalHangs = MainThreadWatchdog.FatalHangSink(began: { hang, start in
            recorder.began(startUptimeNanos: start, elapsedNanos: WatchdogReporting.nanos(hang.duration),
                           addresses: hang.addresses, phase: hang.phase, attribution: nil)
            written.value.store(true, ordering: .releasing)
        }, progressed: { recorder.progressed(elapsedNanos: $0) }, ended: { recorder.ended() })
        watchdog.start()
        let started = ContinuousClock.now
        while (ContinuousClock.now - started < .seconds(3))
            || (!written.value.load(ordering: .acquiring) && ContinuousClock.now - started < .seconds(20)) {}
        kill(getpid(), SIGKILL)
        withExtendedLifetime((marker, watchdog)) {}
    }

    /// Set by the watchdog thread once the record is on disk.
    private final class Written: Sendable {
        let value = Atomic(false)
    }
}
