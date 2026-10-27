@testable import CmuxNextFeed
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The GitHub poll is a repeating background activity (`NSBackgroundActivityScheduler` in the app,
/// a fake here, p14-energy-066b): a refresh at start, one per run of the activity, a new activity on a
/// new interval, and a stop that also stops the refresh that is running. Under Energy Saver the
/// activity runs every four intervals, and while no window shows it is invalidated (p14-energy-032).
@MainActor
@Suite struct GitHubFeedSourcePollTests {
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

    /// One scheduled activity of ``Activities``; the test runs its intent by hand.
    @MainActor private final class Scheduled: BackgroundActivity {
        let request: BackgroundActivityRequest
        let intent: @MainActor @Sendable () -> Void
        private(set) var isValid = true

        init(request: BackgroundActivityRequest, intent: @escaping @MainActor @Sendable () -> Void) {
            self.request = request
            self.intent = intent
        }

        func invalidate() { isValid = false }
    }

    /// Keeps every scheduled activity; ``run()`` runs the live one, as a run's main post would.
    @MainActor private final class Activities: BackgroundActivityScheduling {
        private(set) var scheduled: [Scheduled] = []

        func schedule(_ request: BackgroundActivityRequest,
                      _ intent: @escaping @MainActor @Sendable () -> Void) -> any BackgroundActivity {
            let activity = Scheduled(request: request, intent: intent)
            scheduled.append(activity)
            return activity
        }

        /// The activities not invalidated.
        var live: [Scheduled] { scheduled.filter(\.isValid) }

        /// Runs the one live activity once; false when none, or more than one, is live.
        func run() -> Bool {
            guard live.count == 1, let activity = live.first else { return false }
            activity.intent()
            return true
        }
    }

    @MainActor private final class Rig {
        let clock: ManualClock
        let owner: Owner
        let script: Script
        let calls: AsyncStream<Int>
        let activities: Activities
        let source: GitHubFeedSource

        init(energy: EnergyPolicySource = EnergyPolicySource(), shown: ShownWindows? = nil) {
            let (calls, started) = AsyncStream.makeStream(of: Int.self)
            let clock = ManualClock()
            let owner = Owner()
            let script = Script(started: started)
            let activities = Activities()
            self.clock = clock
            self.owner = owner
            self.script = script
            self.calls = calls
            self.activities = activities
            source = GitHubFeedSource(owner: owner, client: Client(script: script), interval: .seconds(120),
                                      energy: energy, shown: shown, activities: activities, clock: clock)
        }

        /// Waits for the next call to start and returns its number.
        func nextCall() async -> Int? {
            for await call in calls { return call }
            return nil
        }

        /// Waits for the running refresh to end.
        func settle() async { await source.runner?.value }

        /// The interval and tolerance of the one live activity; empty when none, or more than one, is live.
        var schedule: [Duration] {
            guard activities.live.count == 1, let request = activities.live.first?.request else { return [] }
            return [request.interval, request.tolerance]
        }
    }

    @Test(.timeLimit(.minutes(1))) func itRefreshesAtStartThenOncePerRunAndReschedulesOnANewInterval() async throws {
        let rig = Rig()
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()
        #expect(rig.owner.posted == ["github:notification:1"])
        #expect(rig.schedule == [.seconds(120), .seconds(30)], "the activity is not the interval with 25% tolerance")
        let request = try #require(rig.activities.live.first?.request)
        #expect(request.owner == "GitHubFeedSource.refresh")
        #expect(request.workClass == .background)
        #expect(rig.clock.sleeperCount == 0, "the poll still sleeps on a clock")

        #expect(rig.activities.run())
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
        #expect(rig.activities.run())
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
        let old = try #require(rig.activities.live.first)

        rig.source.stop()
        rig.source.start()
        #expect(await rig.nextCall() == 2)
        await rig.settle()
        let settled = rig.source.runner
        old.intent()
        #expect(rig.source.runner == settled, "a replaced activity's run started a refresh")

        await rig.script.hold()
        #expect(rig.activities.run())
        #expect(await rig.nextCall() == 3)
        let running = rig.source.runner
        #expect(rig.activities.run())
        #expect(rig.source.runner == running, "a run during a refresh started another")
        await rig.script.release()
        await rig.settle()
        #expect(await rig.script.notificationETags.count == 3)
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
    /// schedules it and refreshes once when the interval has passed, and only schedules it when not.
    @Test(.timeLimit(.minutes(1))) func hiddenWindowsInvalidateTheActivityAndAShowRefreshesOnce() async throws {
        let shown = ShownWindows()
        let window = VisibilityNode(root: "window", own: .visible)
        shown.track(window)
        let rig = Rig(shown: shown)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()
        let shownActivity = try #require(rig.activities.live.first)

        window.set(.occluded)
        #expect(rig.activities.live.isEmpty, "a hidden app kept its activity")
        rig.clock.advance(by: .seconds(600))
        let hiddenRunner = rig.source.runner
        shownActivity.intent()
        #expect(rig.source.runner == hiddenRunner, "a run posted before the hide refreshed while no window showed")
        #expect(await rig.script.notificationETags.count == 1, "a refresh ran while no window showed")

        window.set(.visible)
        #expect(await rig.nextCall() == 2, "a show past the interval refreshes at once")
        await rig.settle()
        #expect(rig.schedule == [.seconds(120), .seconds(30)])
        #expect(await rig.script.notificationETags.count == 2, "a show refreshed more than once")

        window.set(.hidden)
        rig.clock.advance(by: .seconds(30))
        let settled = rig.source.runner
        window.set(.visible)
        #expect(rig.source.runner == settled, "a show inside the interval refreshed")
        #expect(rig.schedule == [.seconds(120), .seconds(30)], "a show inside the interval did not schedule the activity")
        #expect(await rig.script.notificationETags.count == 2)
        rig.source.stop()
    }

    /// A start while no window shows waits for one, then refreshes at once.
    @Test(.timeLimit(.minutes(1))) func aStartWhileHiddenRefreshesOnTheFirstShow() async throws {
        let shown = ShownWindows()
        let window = VisibilityNode(root: "window", own: .hidden)
        shown.track(window)
        let rig = Rig(shown: shown)
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
        let rig = Rig(shown: shown)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        await rig.settle()

        window.set(.hidden)
        rig.clock.advance(by: .seconds(10))
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
