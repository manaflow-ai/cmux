@testable import CmuxNextApp
import CmuxNextCrashReporting
import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// Two runs in a row that ended before `startup_complete` make the next
/// launch skip every launch cache (reason `crashStreak`), as Chrome falls
/// back to its safe seed after a crash streak
/// (components/variations/service/variations_safe_mode_constants.cc). One
/// run that completes resets the streak.
struct LaunchSafeModeTests {
    @Test func noPreviousRunUsesTheCaches() {
        let streak = LaunchRecovery.crashStreak(previous: nil)
        #expect(streak.unfinishedRuns == 0)
        #expect(streak.launchCaches == .use)
    }

    @Test func oneUnfinishedRunStillUsesTheCaches() {
        let streak = LaunchRecovery.crashStreak(previous: Self.run(unfinishedRuns: 0, completed: false))
        #expect(streak.unfinishedRuns == 1)
        #expect(streak.launchCaches == .use)
    }

    @Test func twoUnfinishedRunsInARowSkipTheCaches() {
        let streak = LaunchRecovery.crashStreak(previous: Self.run(unfinishedRuns: 1, completed: false))
        #expect(streak.unfinishedRuns == 2)
        #expect(streak.launchCaches == .skip(.crashStreak))
        var decoded = 0
        let value: Int? = streak.launchCaches.read { decoded += 1; return 1 }
        #expect(value == nil && decoded == 0, "a skipped launch cache was still decoded")
    }

    @Test func oneCompletedRunResetsTheStreak() {
        #expect(LaunchRecovery.crashStreak(previous: Self.run(unfinishedRuns: 2, completed: true)).unfinishedRuns == 0)
        #expect(LaunchRecovery.crashStreak(previous: Self.run(unfinishedRuns: 5, completed: true)).launchCaches == .use)
    }

    /// A requested quit that was killed before it finished, or a run that
    /// lived past the quick-crash window (longer than the startup
    /// failsafe), is not a startup crash.
    @Test func aRequestedQuitOrALongRunIsNotPartOfAStreak() {
        var quitting = Self.run(unfinishedRuns: 1, completed: false)
        quitting.quitting = true
        #expect(LaunchRecovery.crashStreak(previous: quitting).unfinishedRuns == 0)
        var survived = Self.run(unfinishedRuns: 1, completed: false)
        survived.survived = true
        #expect(LaunchRecovery.crashStreak(previous: survived).unfinishedRuns == 0)
    }

    /// A marker written before the streak fields existed counts as no streak.
    @Test func anOlderMarkerStartsAStreakOfOne() throws {
        let json = #"{"pid":1,"launched":1790000000,"recovery":false,"survived":false,"signal":null,"quitting":false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let previous = try decoder.decode(PreviousRun.self, from: Data(json.utf8))
        #expect(LaunchRecovery.crashStreak(previous: previous).unfinishedRuns == 1)
    }

    /// End to end: a launch cache whose decoder traps ends two launches in
    /// a row; the third launch skips it, completes, and the fourth starts a
    /// new streak. The crash key names the startup task that trapped.
    @Test func aTrappingDecoderIsSkippedAfterTwoCrashedLaunches() async throws {
        let directory = SafeLaunchChild.directory(parent: getpid())
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .failure) { await SafeLaunchChild.launch() }
        await #expect(processExitsWith: .failure) { await SafeLaunchChild.launch() }
        let crashed = try #require(CrashChild.previous(in: directory), "the crashed launch left no run.json")
        #expect(crashed.unfinishedRuns == 1 && crashed.reachedComplete == false)
        #expect(crashed.lastTask == SafeLaunchChild.taskName, "the crash key did not name the running startup task")
        #expect(LaunchRecovery.crashStreak(previous: crashed).launchCaches == .skip(.crashStreak))

        await #expect(processExitsWith: .success) { await SafeLaunchChild.launch() }
        let completed = try #require(CrashChild.previous(in: directory), "the safe launch left no run.json")
        #expect(completed.reachedComplete == true && completed.unfinishedRuns == 2)
        #expect(LaunchRecovery.crashStreak(previous: completed).launchCaches == .use)
    }
}

extension LaunchSafeModeTests {
    fileprivate static func run(unfinishedRuns: Int, completed: Bool) -> PreviousRun {
        PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: false, survived: false,
                    signal: nil, quitting: false, unfinishedRuns: unfinishedRuns, reachedComplete: completed)
    }
}

/// What the exit-test children run: one app launch with a run marker whose
/// launch cache read traps. An exit test captures nothing, so the child
/// finds its marker folder from its parent's pid.
enum SafeLaunchChild {
    static let taskName = "launch.decodeCache"

    static func directory(parent: pid_t) -> URL {
        CrashChild.directory("safe-launch", parent: parent)
    }

    @MainActor
    static func launch() async {
        let marker = AppRunMarker(directory: directory(parent: getppid()))
        _ = await marker.flush()
        marker.startupTaskBegan("launch.decodeCache")
        _ = marker.launchCaches.read(trappingDecode)
        marker.startupCompleted()
        _ = await marker.flush()
        withExtendedLifetime(marker) {}
    }

    /// A decoder that traps on what it reads (an out-of-range index, as a
    /// corrupt length field does).
    private static func trappingDecode() -> Int? {
        let bytes: [UInt8] = []
        return Int(bytes[Int(getpid() & 1) + 1])
    }
}
