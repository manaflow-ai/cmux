import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The app services' launch starts by class (p06-scheduler-049): every start has one; the first-frame
/// starts run in the launch turn; with the feature the others are afterStartup posts that run only after
/// the reveal, each its own `launch.startup_task`; without it (or with no launch scheduler) they run at once.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LaunchStartTests {
    @Test func everyStartHasAClassAndItsOwnName() {
        let firstFrame = LaunchStart.allCases.filter { $0.startClass == .firstFrame }
        let deferred = LaunchStart.allCases.filter { $0.startClass == .afterReveal }
        #expect(LaunchStart.allCases.count == 14)
        #expect(firstFrame == [.energy, .localDaemon, .borders, .glass, .chromiumRuntime, .hibernation, .bookmarks, .historyPages])
        #expect(deferred == [.updateFeed, .cloud, .deviceHub, .historyRetention, .chromiumLikely, .serverUpdates])
        #expect(Set(LaunchStart.allCases.map(\.name.description)).count == LaunchStart.allCases.count, "one signpost name per start")
        #expect(firstFrame.allSatisfy { $0.startClass.priority == nil })
        #expect(deferred.allSatisfy { $0.startClass.priority == .afterStartup })
    }

    @Test func noDeferredStartRunsBeforeTheReveal() {
        let phase = StartupPhase(clock: ManualClock(), ledger: WakeupLedger())
        let s = StartupTestScheduler(phase: phase), ran = StartsRan()
        let deferred = LaunchStart.allCases.filter { $0.startClass == .afterReveal }
        for start in deferred {
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
        for _ in 0..<(deferred.count + 2) { s.fire() }
        #expect(ran.names == deferred.map(\.name.description), "each ran once, in post order")
        #expect(ran.phases.allSatisfy { $0 >= .revealed })
        let records = s.startup.log.records
        #expect(records.map(\.name.description) == deferred.map(\.name.description), "one launch.startup_task per start")
        #expect(records.allSatisfy { $0.priority == .afterStartup && $0.destination == .main && $0.violation == nil })
    }

    @Test func withoutTheFeatureOrALaunchSchedulerEveryStartRunsNow() {
        let s = StartupTestScheduler(), ran = StartsRan()
        LaunchStart.deviceHub.run(on: s.startup, deferring: false) { ran.names.append("off") }
        LaunchStart.serverUpdates.run(on: nil, deferring: true) { ran.names.append("no scheduler") }
        #expect(ran.names == ["off", "no scheduler"], "where the start ran before the feature")
        s.hand.drain()
        #expect(s.startup.log.records.isEmpty, "no post")
    }

    /// Cloud's start has its own post (`CloudStartPost`): it is the same start, under the same name and class.
    @Test func theCloudStartPostIsTheCloudStart() {
        let s = StartupTestScheduler()
        CloudStartPost(startup: s.startup, start: {}).post()
        s.hand.drain()
        let record = s.startup.log.records.first
        #expect(record?.name.description == LaunchStart.cloud.name.description)
        #expect(record?.priority == LaunchStart.cloud.startClass.priority)
    }

    @Test func aFirstFrameStartRunsInTheLaunchTurn() {
        let s = StartupTestScheduler(), ran = StartsRan()
        LaunchStart.localDaemon.run(on: s.startup, deferring: true) { ran.names.append("daemon") }
        LaunchStart.energy.runNow { ran.names.append("energy") }
        #expect(ran.names == ["daemon", "energy"])
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
