import CmuxNextLaunch
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// The app services' launch starts by class (p06-scheduler-049): every start has one; the first-frame
/// starts run in the launch turn, each in its launch-turn signpost as the watchdog's current task; the others
/// run at once (cloud has its own afterStartup post).
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

    @Test func anAfterRevealStartRunsNowWithOrWithoutALaunchScheduler() {
        let s = StartupTestScheduler(), ran = StartsRan()
        LaunchStart.bookmarkSync.run(on: s.startup) { ran.names.append("scheduler") }
        LaunchStart.historyRetention.run(on: nil) { ran.names.append("no scheduler") }
        #expect(ran.names == ["scheduler", "no scheduler"], "where the start ran before its class existed")
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
        LaunchStart.localDaemon.run(on: s.startup) { ran.names.append(s.startup.log.currentMainTask ?? "none") }
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

/// The starts that ran, in order.
@MainActor
private final class StartsRan {
    var names: [String] = []
}
