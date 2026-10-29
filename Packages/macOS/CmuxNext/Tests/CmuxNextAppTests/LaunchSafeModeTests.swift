@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextCrashReporting
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The crash-streak safe launch (Chrome's `VariationsSafeModeTracker`): the run marker records
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

    @Test func theGateDecidesOnceAndMarksASkipOnce() {
        let marks = Marks(), decisions = Marks()
        let gate = LaunchSafeMode.Gate(decide: { decisions.add("decide"); return LaunchSafeMode(incompleteLaunches: 2) },
                                       mark: { marks.add($0) })
        #expect(gate.decision == nil, "nothing is decided before the first ask")
        #expect(!gate.safeMode.readsLaunchCaches)
        #expect(!gate.safeMode.readsLaunchCaches)
        #expect(gate.decision?.reason == .crashStreak)
        #expect(decisions.all == ["decide"], "a later ask decided again")
        #expect(marks.all == ["launch_caches_skipped.crashStreak"])
        let reading = LaunchSafeMode.Gate(decide: { LaunchSafeMode(incompleteLaunches: 1) }, mark: { marks.add($0) })
        #expect(reading.safeMode.readsLaunchCaches)
        #expect(marks.all.count == 1, "a launch that reads its caches marks nothing")
    }

    @Test func aGatedReaderReadsNoFileInASafeLaunch() {
        let reads = Marks()
        let disk = LaunchFileReader(read: { url, _ in reads.add(url.lastPathComponent); return Data([1]) })
        let safe = LaunchSafeMode.Gate(fixed: LaunchSafeMode(incompleteLaunches: 2))
        #expect(disk.gated { safe.safeMode.readsLaunchCaches }.data(at: URL(filePath: "/saved/picture"), maximumBytes: 8) == nil)
        #expect(reads.all.isEmpty, "a safe launch read a launch cache")
        let live = LaunchSafeMode.Gate(fixed: .noStreak)
        #expect(disk.gated { live.safeMode.readsLaunchCaches }.data(at: URL(filePath: "/saved/picture"), maximumBytes: 8) == Data([1]))
        #expect(reads.all == ["picture"])
    }

    /// A launch that ended before its marker was written (a launch cache read on the files lane ended it) left only
    /// its `run.launch`: the next launch counts it, and the decision finds its own record again.
    @Test func aLaunchThatEndedBeforeItsMarkerIsCounted() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-safe-mode-beacon-\(UUID().uuidString)",
                                                                         directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let beacon = directory.appending(path: AppRunMarker.beaconName)
        try LaunchSafeMode.Beacon(pid: getpid() &+ 1, processStart: 7, launched: Date(), bootSession: Self.thisBoot,
                                  incompleteLaunches: 1).store(at: beacon)
        let mode = AppRunMarker.launchSafeMode(directory: directory, bootSession: Self.thisBoot, processStart: 8)
        #expect(mode.reason == .crashStreak, "the launch that ended before its marker was not counted")
        #expect(LaunchSafeMode.Beacon.read(beacon)?.isProcess(pid: getpid(), processStart: 8) == true)
        #expect(AppRunMarker.launchSafeMode(directory: directory, bootSession: Self.thisBoot, processStart: 8) == mode,
                "a second ask of the same launch counted it again")
        try LaunchSafeMode.Beacon(pid: getpid() &+ 1, processStart: 7, launched: Date(), bootSession: Self.earlierBoot,
                                  incompleteLaunches: 1).store(at: beacon)
        #expect(AppRunMarker.launchSafeMode(directory: directory, bootSession: Self.thisBoot, processStart: 9).incompleteLaunches == 1,
                "a machine restart added to the streak")
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

    /// Three launches with a launch cache whose decoder traps on the files lane before the run marker exists (as the
    /// app's `main` reads them, beside the marker's launch read): the first two end before any `run.json`, the third
    /// skips the cache, completes its startup and leaves a marker that resets the streak.
    @Test func aTrappingDecoderIsSkippedOnTheLaunchAfterTwoIncompleteRuns() async throws {
        let directory = CrashChild.directory("safe-mode", parent: getpid())
        try? FileManager.default.removeItem(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let beacon = directory.appending(path: AppRunMarker.beaconName)
        await #expect(processExitsWith: .failure) {
            await SafeModeChild.launch()
        }
        #expect(CrashChild.previous(in: directory) == nil, "the trap ran after the marker")
        #expect(LaunchSafeMode.Beacon.read(beacon)?.incompleteLaunches == 0, "the first launch left no run.launch")
        await #expect(processExitsWith: .failure) {
            await SafeModeChild.launch()
        }
        #expect(LaunchSafeMode.Beacon.read(beacon)?.incompleteLaunches == 1, "the second launch was not counted")
        await #expect(processExitsWith: .success) {
            await SafeModeChild.launch()
        }
        let third = try #require(CrashChild.previous(in: directory), "the third launch left no run.json")
        #expect(third.startupComplete == true)
        #expect(third.incompleteLaunches == 0)
        #expect(third.lastStartupTask == "Settings.takeLaunchRead", "the marker lost the last startup task")
        #expect(third.safeMode(bootSession: AppRunMarker.currentBootSession()) == .noStreak,
                "a completed startup did not reset the streak")
    }
}

/// Strings recorded from any thread (the gate's marks and decisions, a reader's files).
private nonisolated final class Marks: Sendable {
    private let state = Mutex<[String]>([])
    func add(_ value: String) { state.withLock { $0.append(value) } }
    var all: [String] { state.withLock { $0 } }
}

/// The task names ``LaunchSafeModeTests/theSchedulerNamesEachMainTaskUntilCompletion()`` saw begin.
@MainActor
private final class StartedTasks {
    var names: [String] = []
}

/// What the exit-test children run: one app launch each, in the parent's marker folder.
enum SafeModeChild {
    /// As the app's `main`: the launch's gate, a launch cache read on a files lane through the gated reader with a
    /// decoder that traps on what the last quit saved, then the marker's launch read (which asks the same gate), the
    /// marker and a startup with one critical task. Exits 0 once a skipped read completed its startup, 3 when the
    /// skip was not decided as a crash streak.
    @MainActor
    static func launch() async {
        let directory = CrashChild.directory("safe-mode", parent: getppid())
        let gate = LaunchSafeMode.Gate(decide: { AppRunMarker.launchSafeMode(directory: directory) })
        let reader = LaunchFileReader(read: { _, _ in SafeModeChild.decodeSavedPicture() }).gated { gate.safeMode.readsLaunchCaches }
        let work = BackgroundWork(label: "test.safe-mode")
        _ = try? await work.run(.userBlocking, mayBlock: .files) { reader.data(at: directory.appending(path: "saved"), maximumBytes: 64) }
        guard gate.decision?.reason == .crashStreak else { exit(3) }
        let read = AppRunMarker.startLaunchRead(directory: directory, in: work.sequence("test.safe-mode"), gate: gate)
        let marker = AppRunMarker(launch: await read.finished())
        let s = StartupTestScheduler()
        marker.observe(s.startup)
        s.startup.post(.critical, "Settings.takeLaunchRead", on: .main) {}
        _ = await marker.flush()
        s.complete()
        _ = await marker.flush()
        exit(0)
    }

    /// A launch cache's decoder that traps on its file.
    private nonisolated static func decodeSavedPicture() -> Data? {
        fatalError("the saved picture does not decode")
    }
}
