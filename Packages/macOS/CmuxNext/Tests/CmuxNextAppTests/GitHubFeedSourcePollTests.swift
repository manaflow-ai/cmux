@testable import CmuxNextFeed
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The GitHub poll is a repeating background activity (`NSBackgroundActivityScheduler` in the app,
/// a fake here): a refresh at start, one per run of the activity, a new activity on a
/// new interval, and a stop that also stops the refresh that is running. Under Energy Saver the
/// activity runs every four intervals, and while no feed surface shows it is invalidated.
@MainActor
@Suite(.serialized) struct GitHubFeedSourcePollTests {
    /// Answers notification `n` (ETag `n-<n>`) to the n-th call, records each call's ETag, and
    /// holds a call while the test asks it to.
    private actor Script {
        private(set) var notificationETags: [String?] = []
        private var holding = false
        private var gate: CheckedContinuation<Void, Never>?
        private let started: AsyncStream<Int>.Continuation

        init(started: AsyncStream<Int>.Continuation) { self.started = started }

        func hold() { holding = true }

        func release() {
            holding = false
            gate?.resume()
            gate = nil
        }

        func notifications(etag: String?) async -> GitHubAPIResponse<[GitHubNotification]> {
            notificationETags.append(etag)
            let call = notificationETags.count
            started.yield(call)
            if holding { await withCheckedContinuation { gate = $0 } }
            let notification = GitHubNotification(
                id: "\(call)", reason: "mention", subject: .init(title: "Call \(call)"),
                repository: .init(fullName: "acme/app"), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            return GitHubAPIResponse(value: [notification], etag: "n-\(call)")
        }
    }

    nonisolated private struct Client: GitHubFeedAPI {
        let script: Script
        func notifications(etag: String?) async throws -> GitHubAPIResponse<[GitHubNotification]> {
            await script.notifications(etag: etag)
        }
        func reviewRequests(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
            GitHubAPIResponse(value: [])
        }
    }

    @MainActor private final class Owner: FeedPostingSource {
        var posted: [String] = []
        func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {}
        func send(_ intent: FeedIntent) {}
        func stop() {}
        func post(_ item: FeedItem) { posted.append(item.dedupeKey ?? item.id) }
    }

    /// The intents the activity's runs posted to the main actor, run when the test says, as the
    /// app's main work scheduler runs them on a later turn.
    @MainActor private final class Posted {
        private(set) var intents: [@MainActor @Sendable () -> Void] = []

        func append(_ intent: @escaping @MainActor @Sendable () -> Void) { intents.append(intent) }

        /// Runs the posted intents once, the oldest first; returns how many ran.
        @discardableResult
        func run() -> Int {
            let due = intents
            intents.removeAll()
            due.forEach { $0() }
            return due.count
        }
    }

    @MainActor private final class Rig {
        let owner: Owner
        let script: Script
        let calls: AsyncStream<Int>
        let activities: ManualBackgroundActivityScheduler
        let posted: Posted
        /// The main deadlines the catch-up after a show is booked on; their uptime times the interval since the last refresh.
        let deadlines: MainDeadlineRig
        let source: GitHubFeedSource

        init(energy: EnergyPolicySource = EnergyPolicySource(), surfaces: ShownWindows? = nil) {
            let (calls, started) = AsyncStream.makeStream(of: Int.self)
            let owner = Owner()
            let script = Script(started: started)
            let activities = ManualBackgroundActivityScheduler()
            let posted = Posted()
            let deadlines = MainDeadlineRig()
            self.owner = owner
            self.script = script
            self.calls = calls
            self.activities = activities
            self.posted = posted
            self.deadlines = deadlines
            let intents = MainIntentBackgroundActivities(activities: activities) { _, intent in await posted.append(intent) }
            source = GitHubFeedSource(owner: owner, client: Client(script: script), interval: .seconds(120),
                                      energy: energy, surfaces: surfaces, activities: intents,
                                      activityIdentifier: GitHubFeedSource.refreshActivityIdentifier(bundleID: "com.cmuxterm.app.next.test"),
                                      deadlines: deadlines.deadlines)
        }

        /// Waits for the next call to start and returns its number.
        func nextCall() async -> Int? {
            for await call in calls { return call }
            return nil
        }

        /// Moves the deadlines' uptime on, firing nothing on them.
        func advance(by duration: Duration) { deadlines.advance(by: duration) }

        /// Waits for the running refresh to end.
        func settle() async { await source.runner?.value }

        /// The interval and tolerance of the one live activity; empty when none, or more than one, is live.
        var schedule: [Duration] {
            guard activities.live.count == 1, let activity = activities.live.first else { return [] }
            return [activity.interval, activity.tolerance]
        }

        /// One run of the one live activity, its intent run on the main actor; false when none, or
        /// more than one, is live.
        func run() async -> Bool {
            guard activities.live.count == 1 else { return false }
            await activities.fire()
            return posted.run() == 1
        }
    }

    @Test(.timeLimit(.minutes(1))) func itRefreshesAtStartThenOncePerRunAndReschedulesOnANewInterval() async throws {
        let rig = Rig()
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()
        #expect(rig.owner.posted == ["github:notification:1"])
        #expect(rig.schedule == [.seconds(120), .seconds(30)], "the activity is not the interval with 25% tolerance")
        let activity = try #require(rig.activities.live.first)
        #expect(activity.owner == "GitHubFeedSource.refresh")
        #expect(activity.identifier == "com.cmuxterm.app.next.test.github-feed.refresh", "the identifier does not start with the bundle id")
        #expect(!rig.deadlines.hasArmedWake, "the poll still books a deadline between refreshes")

        #expect(await rig.run())
        #expect(await rig.nextCall() == 2)
        await rig.settle()
        #expect(await rig.script.notificationETags == [nil, "n-1"])

        // A new interval restarts the poll: one refresh now, and an activity at the new interval.
        rig.source.setInterval(.seconds(30))
        #expect(await rig.nextCall() == 3)
        await rig.settle()
        #expect(rig.schedule == [.seconds(30), .milliseconds(7_500)])

        rig.source.stop()
        #expect(rig.activities.live.isEmpty, "a stop left the activity scheduled")
        #expect(rig.owner.posted == ["github:notification:1", "github:notification:2", "github:notification:3"])
    }

    /// A stop (GitHub turned off, sign-out, disconnect) during an activity's refresh: the refresh
    /// posts nothing and writes no ETag over the reset, so the next start asks without one.
    @Test(.timeLimit(.minutes(1))) func aStopDuringAnActivityRefreshDropsItsResults() async throws {
        let rig = Rig()
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()

        await rig.script.hold()
        #expect(await rig.run())
        #expect(await rig.nextCall() == 2)
        let stopped = try #require(rig.source.runner)
        rig.source.stop()
        rig.source.resetConditionalRequests()
        await rig.script.release()
        await stopped.value

        #expect(rig.owner.posted == ["github:notification:1"])
        #expect(rig.source.githubDetails.isEmpty)
        #expect(rig.activities.live.isEmpty)

        rig.source.start()
        #expect(await rig.nextCall() == 3)
        #expect(await rig.script.notificationETags == [nil, "n-1", nil])
        await rig.settle()
        #expect(rig.owner.posted == ["github:notification:1", "github:notification:3"])
        rig.source.stop()
    }

    /// A run of an activity a restart replaced (posted before the restart) starts no refresh; nor
    /// does a run while a refresh still runs.
    @Test(.timeLimit(.minutes(1))) func aStaleOrOverlappingRunStartsNoRefresh() async throws {
        let rig = Rig()
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()
        #expect(await rig.activities.fire() == 1, "the old activity's run did not post before the restart")

        rig.source.stop()
        rig.source.start()
        #expect(await rig.nextCall() == 2)
        await rig.settle()
        let settled = rig.source.runner
        #expect(rig.posted.run() == 1)
        #expect(rig.source.runner == settled, "a replaced activity's run started a refresh")

        await rig.script.hold()
        #expect(await rig.run())
        #expect(await rig.nextCall() == 3)
        let running = rig.source.runner
        #expect(await rig.run())
        #expect(rig.source.runner == running, "a run during a refresh started another")
        await rig.script.release()
        await rig.settle()
        #expect(await rig.script.notificationETags.count == 3)
        rig.source.stop()
    }

    /// A run posted before a hide reaches the main thread after the show that followed: the show
    /// scheduled a new activity, and the old one's intent starts no second refresh. Nor does one
    /// posted before an Energy Saver edge scheduled the activity anew.
    @Test(.timeLimit(.minutes(1))) func aRunOfAReplacedActivityStartsNoRefreshAfterAShow() async throws {
        let shown = ShownWindows()
        let window = VisibilityNode(root: "window", own: .visible)
        shown.track(window)
        let energy = EnergyPolicySource()
        let rig = Rig(energy: energy, surfaces: shown)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()
        #expect(await rig.activities.fire() == 1, "the activity's run did not post before the hide")

        window.set(.hidden)
        rig.advance(by: .seconds(600))
        window.set(.visible)
        #expect(await rig.nextCall() == 2, "a show past the interval refreshes at once")
        await rig.settle()
        let settled = rig.source.runner
        #expect(rig.posted.run() == 1)
        #expect(rig.source.runner == settled, "the hidden activity's run refreshed again after the show")
        #expect(await rig.script.notificationETags.count == 2)

        #expect(await rig.activities.fire() == 1, "the shown activity's run did not post before the saver edge")
        energy.update(EnergyPolicy(saverReason: .battery))
        #expect(rig.schedule == [.seconds(480), .seconds(120)])
        #expect(rig.posted.run() == 1)
        #expect(rig.source.runner == settled, "the run of the activity the saver replaced refreshed")
        #expect(await rig.script.notificationETags.count == 2)
        rig.source.stop()
    }

    /// The poll follows the feed's own surfaces, not the window: with the window shown and the feed's
    /// node hidden (no feed tab, panel or sidebar section shows) the activity is invalidated, and the
    /// feed showing again past the interval refreshes once and schedules it.
    @Test(.timeLimit(.minutes(1))) func aHiddenFeedSurfaceInAShownWindowInvalidatesTheActivity() async throws {
        let surfaces = ShownWindows()
        let window = VisibilityNode(root: "window", own: .visible)
        let feed = VisibilityNode("feed:sidebar", own: .visible, parent: window)
        surfaces.track(feed)
        let rig = Rig(surfaces: surfaces)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()
        #expect(rig.schedule == [.seconds(120), .seconds(30)])

        feed.set(.hidden)
        #expect(window.isVisible)
        #expect(rig.activities.live.isEmpty, "a shown window with no feed kept the poll activity")
        rig.advance(by: .seconds(600))
        #expect(await rig.script.notificationETags.count == 1, "a refresh ran while no feed showed")

        feed.set(.visible)
        #expect(await rig.nextCall() == 2, "a feed showing past the interval did not refresh at once")
        await rig.settle()
        #expect(rig.schedule == [.seconds(120), .seconds(30)])
        #expect(await rig.script.notificationETags.count == 2, "a feed show refreshed more than once")
        rig.source.stop()
    }

    // MARK: p14-energy-032, 066b

    /// Under Energy Saver the activity runs every four intervals, and the saver's edges schedule it anew.
    @Test(.timeLimit(.minutes(1))) func theSaverStretchesTheIntervalFourTimes() async throws {
        let energy = EnergyPolicySource(EnergyPolicy(saverReason: .lowPowerMode))
        let rig = Rig(energy: energy)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()
        #expect(rig.schedule == [.seconds(480), .seconds(120)])

        energy.update(.normal)
        #expect(rig.schedule == [.seconds(120), .seconds(30)], "the saver's end kept the stretched activity")
        #expect(rig.activities.scheduled.count == 2)
        energy.update(EnergyPolicy(saverReason: .battery))
        #expect(rig.schedule == [.seconds(480), .seconds(120)])
        #expect(rig.activities.scheduled.count == 3)
        #expect(await rig.script.notificationETags.count == 1, "a saver edge refreshed")
        rig.source.stop()
    }

    /// With every window hidden the activity is invalidated, however long; a window showing again
    /// refreshes once and schedules it when the interval has passed. A show inside the interval
    /// refreshes at the interval's end (last refresh + interval, not show + interval) and schedules
    /// the activity then; a hide meanwhile drops that refresh and a show again books the same end.
    @Test(.timeLimit(.minutes(1))) func hiddenWindowsInvalidateTheActivityAndAShowRefreshesOnce() async throws {
        let shown = ShownWindows()
        let window = VisibilityNode(root: "window", own: .visible)
        shown.track(window)
        let rig = Rig(surfaces: shown)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()
        #expect(await rig.activities.fire() == 1, "the activity's run did not post before the hide")

        window.set(.occluded)
        #expect(rig.activities.live.isEmpty, "a hidden app kept its activity")
        rig.advance(by: .seconds(600))
        let hiddenRunner = rig.source.runner
        #expect(rig.posted.run() == 1)
        #expect(rig.source.runner == hiddenRunner, "a run posted before the hide refreshed while no window showed")
        #expect(await rig.script.notificationETags.count == 1, "a refresh ran while no window showed")

        window.set(.visible)
        #expect(await rig.nextCall() == 2, "a show past the interval refreshes at once")
        await rig.settle()
        #expect(rig.schedule == [.seconds(120), .seconds(30)])
        #expect(await rig.script.notificationETags.count == 2, "a show refreshed more than once")

        // The last refresh ended at 600 s: a show at 630 s refreshes at 720 s.
        window.set(.hidden)
        rig.advance(by: .seconds(30))
        let settled = rig.source.runner
        window.set(.visible)
        #expect(rig.source.catchUpDue == .seconds(720), "a show inside the interval does not book its rest")
        #expect(rig.source.runner == settled, "a show inside the interval refreshed at once")
        #expect(rig.activities.live.isEmpty, "a show inside the interval scheduled the activity a whole interval from the show")

        window.set(.hidden)
        #expect(rig.source.catchUpDue == nil, "a hide kept the refresh at the interval's end")
        #expect(!rig.deadlines.hasArmedWake)
        rig.advance(by: .seconds(30))
        window.set(.visible)
        #expect(rig.source.catchUpDue == .seconds(720), "a second show moved the interval's end")

        rig.advance(by: .seconds(30))
        rig.deadlines.fireAtNow()
        #expect(rig.source.runner == settled, "the refresh came before the interval's end")
        rig.advance(by: .seconds(30))
        rig.deadlines.fireAndRun()
        #expect(await rig.nextCall() == 3, "no refresh came at the interval's end")
        await rig.settle()
        #expect(rig.schedule == [.seconds(120), .seconds(30)], "the refresh at the interval's end did not schedule the activity")
        #expect(await rig.script.notificationETags.count == 3)
        rig.source.stop()
    }

    /// An Energy Saver edge while a show waits for the interval's end books the rest of the new interval.
    @Test(.timeLimit(.minutes(1))) func aSaverEdgeDuringTheWaitBooksTheRestOfTheNewInterval() async throws {
        let energy = EnergyPolicySource()
        let shown = ShownWindows()
        let window = VisibilityNode(root: "window", own: .visible)
        shown.track(window)
        let rig = Rig(energy: energy, surfaces: shown)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()

        window.set(.hidden)
        rig.advance(by: .seconds(60))
        window.set(.visible)
        #expect(rig.source.catchUpDue == .seconds(120))

        energy.update(EnergyPolicy(saverReason: .battery))
        #expect(rig.source.catchUpDue == .seconds(480), "the saver kept the unstretched end")
        #expect(rig.activities.live.isEmpty)
        rig.advance(by: .seconds(420))
        rig.deadlines.fireAndRun()
        #expect(await rig.nextCall() == 2)
        await rig.settle()
        #expect(rig.schedule == [.seconds(480), .seconds(120)])
        rig.source.stop()
    }

    /// A start while no window shows waits for one, then refreshes at once.
    @Test(.timeLimit(.minutes(1))) func aStartWhileHiddenRefreshesOnTheFirstShow() async throws {
        let shown = ShownWindows()
        let window = VisibilityNode(root: "window", own: .hidden)
        shown.track(window)
        let rig = Rig(surfaces: shown)
        rig.source.start()
        #expect(rig.source.runner == nil, "a hidden start refreshed")
        #expect(rig.activities.scheduled.isEmpty, "a hidden start scheduled the activity")
        window.set(.visible)
        #expect(await rig.nextCall() == 1)
        await rig.settle()
        #expect(rig.schedule == [.seconds(120), .seconds(30)])
        rig.source.stop()
    }

    /// A restart while no window shows (a new interval, an account change, a reconnect) forgets
    /// the old generation's last refresh: the first show refreshes at once, as a shown restart does.
    @Test(.timeLimit(.minutes(1))) func aRestartWhileHiddenRefreshesAtOnceOnTheFirstShow() async throws {
        let shown = ShownWindows()
        let window = VisibilityNode(root: "window", own: .visible)
        shown.track(window)
        let rig = Rig(surfaces: shown)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()

        window.set(.hidden)
        rig.advance(by: .seconds(10))
        rig.source.stop()
        rig.source.start()
        #expect(rig.source.runner == nil, "a hidden restart refreshed")
        #expect(rig.activities.live.isEmpty)

        window.set(.visible)
        #expect(await rig.nextCall() == 2, "a show after a hidden restart did not refresh at once")
        await rig.settle()
        #expect(rig.schedule == [.seconds(120), .seconds(30)])
        #expect(await rig.script.notificationETags.count == 2)
        rig.source.stop()
    }
}
