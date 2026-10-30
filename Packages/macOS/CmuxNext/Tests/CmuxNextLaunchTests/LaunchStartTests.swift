import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The app services' launch starts by class (p06-scheduler-049): every start has one; the first-frame
/// starts run in the launch turn, each in its launch-turn signpost as the watchdog's current task; with the
/// feature the others are afterStartup posts that run only after the reveal, each its own
/// `launch.startup_task`; without it (or with no launch scheduler) they run at once.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchStartTests {
    private static let deferred: [LaunchStart] = [.cloud, .historyRetention, .chromiumLikely, .bookmarkSync]

    @Test func everyStartHasAClassAndItsOwnName() {
        let firstFrame = LaunchStart.allCases.filter { $0.startClass == .firstFrame }
        #expect(LaunchStart.allCases.filter { $0.startClass == .afterReveal } == Self.deferred)
        #expect(firstFrame.count + Self.deferred.count == LaunchStart.allCases.count)
        #expect(firstFrame.contains(.bookmarks) && Self.deferred.contains(.bookmarkSync), "the store first, its sync after")
        #expect(Set(LaunchStart.allCases.map(\.name.description)).count == LaunchStart.allCases.count, "one signpost name per start")
        #expect(firstFrame.allSatisfy { $0.startClass.priority == nil })
        #expect(Self.deferred.allSatisfy { $0.startClass.priority == .afterStartup })
        // A first-frame start that has a critical row is named as there (startup-DESIGN.md section 1).
        let critical = Set(StartupScheduler.criticalAllowlist.map(\.description))
        for start in [LaunchStart.localDaemon, .featurePolicy, .managedPolicy] {
            #expect(critical.contains(start.name.description), "\(start.name)")
        }
    }

    @Test func noDeferredStartRunsBeforeTheReveal() {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let s = StartupTestScheduler(phase: phase), ran = StartsRan()
        for start in Self.deferred {
            start.run(on: s.startup, deferring: true) { ran.names.append(start.name.description); ran.phases.append(phase.phase) }
        }
        s.hand.drain()
        s.complete()
        for _ in 0..<4 { s.fire() }
        #expect(ran.names.isEmpty, "launching: no deferred start ran")
        phase.noteFirstFrame()
        for _ in 0..<4 { s.fire() }
        #expect(ran.names.isEmpty, "revealed: they wait for startup to complete")
        for reference in [StartupPhase.Reference.firstSnapshot, .restoreDone, .visiblePageIdle] { phase.markDone(reference) }
        s.hand.drain()
        #expect(s.startup.completion != nil)
        for _ in 0..<(Self.deferred.count + 2) { s.fire() }
        #expect(ran.names == Self.deferred.map(\.name.description), "each ran once, in post order")
        #expect(ran.phases.allSatisfy { $0 >= .revealed })
        let records = s.startup.log.records
        #expect(records.map(\.name.description) == Self.deferred.map(\.name.description), "one launch.startup_task per start")
        #expect(records.allSatisfy { $0.priority == .afterStartup && $0.destination == .main && $0.violation == nil })
    }

    @Test func withoutTheFeatureOrALaunchSchedulerEveryStartRunsNow() {
        let s = StartupTestScheduler(), ran = StartsRan()
        LaunchStart.bookmarkSync.run(on: s.startup, deferring: false) { ran.names.append("off") }
        LaunchStart.historyRetention.run(on: nil, deferring: true) { ran.names.append("no scheduler") }
        #expect(ran.names == ["off", "no scheduler"], "where the start ran before the feature")
        s.hand.drain()
        #expect(s.startup.log.records.isEmpty, "no post")
    }

    /// Cloud's start has its own post (`CloudStartPost`): it posts the enum's start, under its name and class.
    @Test func theCloudStartPostIsTheCloudStart() {
        let s = StartupTestScheduler()
        CloudStartPost(startup: s.startup, start: {}).post()
        s.hand.drain()
        let record = s.startup.log.records.first
        #expect(record?.name.description == LaunchStart.cloud.name.description)
        #expect(record?.priority == LaunchStart.cloud.startClass.priority)
    }

    /// A first-frame start is a direct call in the launch turn: no post, no record, and while it runs it is the
    /// watchdog's current main task (its `launch.startup_task` interval, `priority=launchTurn`, is around it).
    @Test func aFirstFrameStartRunsInTheLaunchTurnAsTheCurrentTask() {
        let s = StartupTestScheduler(), ran = StartsRan()
        LaunchStart.localDaemon.run(on: s.startup, deferring: true) { ran.names.append(s.startup.log.currentMainTask ?? "none") }
        let made = LaunchStart.browserProfiles.runNow(on: s.startup) { () -> Int in
            ran.names.append(s.startup.log.currentMainTask ?? "none")
            return 7
        }
        LaunchStart.energy.runNow(on: nil) { ran.names.append(s.startup.log.currentMainTask ?? "none") }
        #expect(made == 7, "the start's value comes back")
        #expect(ran.names == ["Daemon.start", "BrowserProfiles.load", "none"])
        #expect(s.startup.log.currentMainTask == nil, "the word is cleared after the start")
        s.hand.drain()
        #expect(s.startup.log.records.isEmpty, "a first-frame start is a direct call, not a post")
    }
}

/// The starts that ran and the phase each ran in, in order.
@MainActor
private final class StartsRan {
    var names: [String] = []
    var phases: [StartupPhase.Phase] = []
}
