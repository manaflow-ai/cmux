@testable import CmuxNextApp
import CmuxNextCrashReporting
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The crash-streak safe launch (p08-startup-089, Chrome's `VariationsSafeModeTracker`): the run marker records
/// whether a run's startup completed and the last startup task it began; after two runs in a row ended before their
/// startup completed, the launch reads no launch cache, and a completed startup resets the streak.
struct LaunchSafeModeTests {
    private static let thisBoot = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
    private static let earlierBoot = "ffeeddccbbaa99887766554433221100"

    /// A run the marker left: ended with no handler running (a kill, or a hang Force Quit) unless `signal` says.
    private static func run(complete: Bool?, before: Int?, signal: Int32? = nil, quitting: Bool? = false,
                            boot: String? = thisBoot) -> PreviousRun {
        PreviousRun(pid: 4242, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: false, survived: false,
                    signal: signal, quitting: quitting, bootSession: boot, startupComplete: complete, incompleteLaunches: before)
    }

    /// The marker's decision: no `run.json` (a normal quit removes it) reads the caches.
    private static func decide(_ previous: PreviousRun?) -> LaunchSafeMode {
        previous?.safeMode(bootSession: thisBoot) ?? .noStreak
    }

    @Test func noIncompleteRunReadsTheCaches() {
        #expect(Self.decide(nil) == .noStreak, "a normal quit removes the marker")
        #expect(Self.decide(nil).readsLaunchCaches)
    }

    @Test func oneIncompleteRunStillReadsTheCaches() {
        let mode = Self.decide(Self.run(complete: false, before: 0, signal: SIGSEGV))
        #expect(mode.incompleteLaunches == 1)
        #expect(mode.reason == nil)
        #expect(mode.readsLaunchCaches, "one crash at launch is not a streak")
    }

    @Test func twoIncompleteRunsInARowSkipTheCaches() {
        let mode = Self.decide(Self.run(complete: false, before: 1))
        #expect(mode.incompleteLaunches == 2)
        #expect(mode.reason == .crashStreak)
        #expect(!mode.readsLaunchCaches)
        #expect(Self.decide(Self.run(complete: false, before: 2, signal: SIGTRAP)).reason == .crashStreak,
                "a safe launch that also ends before completion keeps the next one safe")
    }

    @Test func aCompletedStartupResetsTheStreak() {
        #expect(Self.decide(Self.run(complete: true, before: 0, signal: SIGSEGV)) == .noStreak,
                "a crash after the startup completed is no launch cache's")
    }

    @Test func aQuitAskedForResetsTheStreak() {
        #expect(Self.decide(Self.run(complete: false, before: 3, quitting: true)) == .noStreak)
        #expect(Self.decide(Self.run(complete: false, before: 3, signal: SIGTERM)) == .noStreak)
    }

    @Test func aMarkerFromBeforeTheFieldNeverCounts() {
        #expect(Self.decide(Self.run(complete: nil, before: nil)) == .noStreak)
    }

    @Test func aRestartOfTheMachineNeitherAddsNorResets() {
        let mode = Self.decide(Self.run(complete: false, before: 2, boot: Self.earlierBoot))
        #expect(mode.incompleteLaunches == 2)
        #expect(mode.reason == .crashStreak)
    }

    @Test func aSkippedReadRecordsItsReasonAndRunsNothing() {
        var marks: [String] = [], reads = 0
        LaunchSafeMode(incompleteLaunches: 2).readLaunchCaches(mark: { marks.append($0) }) { reads += 1 }
        #expect(reads == 0)
        #expect(marks == ["launch_caches_skipped.crashStreak"])
        LaunchSafeMode(incompleteLaunches: 1).readLaunchCaches(mark: { marks.append($0) }) { reads += 1 }
        #expect(reads == 1)
        #expect(marks.count == 1, "a read launch marks nothing")
    }

    /// The scheduler names each main task to the marker as it begins, until startup completes.
    @MainActor @Test func theSchedulerNamesEachMainTaskUntilCompletion() {
        let s = StartupTestScheduler(), started = StartedTasks()
        s.startup.taskStarted = { started.names.append($0.description) }
        s.startup.post(.critical, "Settings.takeLaunchRead", on: .main) {}
        s.startup.post(.afterFirstFrame, "Updater.start", on: .main) {}
        s.startup.finishRegistration()
        s.startup.firstFrameCommitted()
        s.fire()
        s.hand.drain()
        #expect(s.startup.completion != nil)
        #expect(s.startup.taskStarted == nil, "the hook is dropped at completion")
        s.startup.post(.afterStartup, "Palette.prepare", on: .main) {}
        s.fire()
        #expect(started.names == ["Settings.takeLaunchRead", "Updater.start"])
        s.startup.beginQuit()
    }

    /// Three launches with a launch cache whose decoder traps: the first two end before their startup completed,
    /// the third skips the cache, completes its startup and leaves a marker that resets the streak.
    @Test func aTrappingDecoderIsSkippedOnTheLaunchAfterTwoIncompleteRuns() async throws {
        let directory = CrashChild.directory("safe-mode", parent: getpid())
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .failure) {
            await SafeModeChild.launch()
        }
        let first = try #require(CrashChild.previous(in: directory), "the first launch left no run.json")
        #expect(first.startupComplete == false)
        #expect(first.incompleteLaunches == 0)
        #expect(first.lastStartupTask == "Settings.takeLaunchRead", "the marker lost the last startup task")
        await #expect(processExitsWith: .failure) {
            await SafeModeChild.launch()
        }
        let second = try #require(CrashChild.previous(in: directory), "the second launch left no run.json")
        #expect(second.incompleteLaunches == 1)
        #expect(second.safeMode(bootSession: AppRunMarker.currentBootSession()).reason == .crashStreak)
        await #expect(processExitsWith: .success) {
            await SafeModeChild.launch()
        }
        let third = try #require(CrashChild.previous(in: directory), "the third launch left no run.json")
        #expect(third.startupComplete == true)
        #expect(third.incompleteLaunches == 0)
        #expect(third.safeMode(bootSession: AppRunMarker.currentBootSession()) == .noStreak,
                "a completed startup did not reset the streak")
    }
}

/// The task names ``LaunchSafeModeTests/theSchedulerNamesEachMainTaskUntilCompletion()`` saw begin.
@MainActor
private final class StartedTasks {
    var names: [String] = []
}

/// What the exit-test children run: one app launch each, in the parent's marker folder.
enum SafeModeChild {
    /// The marker, a startup with one critical task, then the launch caches' read as the app's `main` makes it, with
    /// a decoder that traps on what the last quit saved. Exits 0 once a skipped read completed its startup, 3 when
    /// the skip recorded no mark.
    @MainActor
    static func launch() async {
        let marker = AppRunMarker(directory: CrashChild.directory("safe-mode", parent: getppid()))
        let s = StartupTestScheduler()
        marker.observe(s.startup)
        s.startup.post(.critical, "Settings.takeLaunchRead", on: .main) {}
        _ = await marker.flush()
        var marks: [String] = []
        marker.safeMode.readLaunchCaches(mark: { marks.append($0) }) { decodeSavedPicture() }
        guard marks == [LaunchSafeMode.Reason.crashStreak.mark] else { exit(3) }
        s.complete()
        _ = await marker.flush()
        exit(0)
    }

    /// A launch cache's decoder that traps on its file.
    private static func decodeSavedPicture() {
        fatalError("the saved picture does not decode")
    }
}
