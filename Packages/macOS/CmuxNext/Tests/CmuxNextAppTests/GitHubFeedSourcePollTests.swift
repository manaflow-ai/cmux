@testable import CmuxNextFeed
import CmuxNextWakeups
import Foundation
import Testing

/// The GitHub poll is a self-rescheduling background `MainDeadline` on the app's deadline scheduler
/// (p14-energy-019c, p06-scheduler-344): a refresh at start, the next one an interval after each ends, a restart
/// on a new interval, and a stop that also stops the refresh that is running. Under Energy Saver it waits four
/// intervals, while no window shows it books nothing (p14-energy-032), and while the app is hidden its booked
/// refresh is aligned on the app's node (Blink's hidden-page timer alignment).
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

    /// The source on a deadline scheduler whose uptime and wakes the test moves by hand.
    @MainActor private final class Rig {
        let deadlines = MainDeadlineRig()
        let owner: Owner
        let script: Script
        let calls: AsyncStream<Int>
        let source: GitHubFeedSource

        init(energy: EnergyPolicySource = EnergyPolicySource(), shown: ShownWindows? = nil, appNode: VisibilityNode? = nil) {
            let (calls, started) = AsyncStream.makeStream(of: Int.self)
            let owner = Owner()
            let script = Script(started: started)
            self.owner = owner
            self.script = script
            self.calls = calls
            source = GitHubFeedSource(owner: owner, client: Client(script: script), interval: .seconds(120),
                                      energy: energy, shown: shown, deadlines: deadlines.deadlines, appNode: appNode)
        }

        /// Waits for the next call to start and returns its number.
        func nextCall() async -> Int? {
            for await call in calls { return call }
            return nil
        }

        /// Waits until the running refresh has ended and booked the next one; returns when that one is due, in
        /// seconds of the rig's uptime.
        func booking() async throws -> Double {
            for _ in 0..<10_000 where !source.nextRefresh.isScheduled { await Task.yield() }
            let wake = try #require(source.nextRefresh.plannedWake, "no refresh was booked")
            return Double(wake.due.components.seconds) + Double(wake.due.components.attoseconds) / 1e18
        }

        /// Fires the booked refresh at its wake and runs its posted action.
        func fire() { deadlines.fireAndRun() }

        var isBooked: Bool { source.nextRefresh.isScheduled }
    }

    @Test(.timeLimit(.minutes(1))) func itRefreshesAtStartThenOncePerIntervalAndRestartsOnANewInterval() async throws {
        let rig = Rig()
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        #expect(try await rig.booking() == 120)
        #expect(rig.owner.posted == ["github:notification:1"])
        #expect(rig.source.nextRefresh.workClass == .background, "nobody waits on the poll: it must not compete with the person")
        #expect(rig.source.nextRefresh.owner == GitHubFeedSource.refreshOwner)

        rig.fire()
        #expect(await rig.nextCall() == 2)
        #expect(try await rig.booking() == 240)
        #expect(await rig.script.notificationETags == [nil, "n-1"])

        // A new interval restarts the poll: one refresh now, the next one 30 s after it.
        rig.source.setInterval(.seconds(30))
        #expect(!rig.isBooked)
        #expect(await rig.nextCall() == 3)
        #expect(try await rig.booking() == 150)

        rig.source.stop()
        #expect(!rig.isBooked)
        #expect(rig.owner.posted == ["github:notification:1", "github:notification:2", "github:notification:3"])
    }

    /// A stop (GitHub turned off, sign-out, disconnect) during a timer-fired refresh: the refresh
    /// posts nothing and writes no ETag over the reset, so the next start asks without one.
    @Test(.timeLimit(.minutes(1))) func aStopDuringATimerRefreshDropsItsResults() async throws {
        let rig = Rig()
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        _ = try await rig.booking()

        await rig.script.hold()
        rig.fire()
        #expect(await rig.nextCall() == 2)
        let stopped = try #require(rig.source.runner)
        rig.source.stop()
        rig.source.resetConditionalRequests()
        await rig.script.release()
        await stopped.value

        #expect(rig.owner.posted == ["github:notification:1"])
        #expect(rig.source.githubDetails.isEmpty)
        #expect(!rig.isBooked)

        rig.source.start()
        #expect(await rig.nextCall() == 3)
        #expect(await rig.script.notificationETags == [nil, "n-1", nil])
        _ = try await rig.booking()
        #expect(rig.owner.posted == ["github:notification:1", "github:notification:3"])
        rig.source.stop()
    }

    // MARK: p14-energy-032

    /// Under Energy Saver the next refresh waits four intervals.
    @Test(.timeLimit(.minutes(1))) func theSaverStretchesTheIntervalFourTimes() async throws {
        let rig = Rig(energy: EnergyPolicySource(EnergyPolicy(saverReason: .lowPowerMode)))
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        #expect(try await rig.booking() == 480)
        rig.source.stop()
    }

    /// With every window hidden no refresh is booked, however long; a window showing again refreshes
    /// once when the interval has passed, and books the rest of it when it has not.
    @Test(.timeLimit(.minutes(1))) func hiddenWindowsBookNoRefreshAndAShowRefreshesOnce() async throws {
        let shown = ShownWindows()
        let window = VisibilityNode(root: "window", own: .visible)
        shown.track(window)
        let rig = Rig(shown: shown)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        _ = try await rig.booking()

        window.set(.occluded)
        #expect(!rig.isBooked, "a hidden app kept its next refresh")
        rig.deadlines.advance(by: .seconds(600))
        #expect(!rig.isBooked)
        #expect(await rig.script.notificationETags.count == 1, "a refresh ran while no window showed")

        window.set(.visible)
        #expect(await rig.nextCall() == 2, "a show past the interval refreshes at once")
        #expect(try await rig.booking() == 720)
        #expect(await rig.script.notificationETags.count == 2, "a show refreshed more than once")

        window.set(.hidden)
        rig.deadlines.advance(by: .seconds(30))
        window.set(.visible)
        #expect(try await rig.booking() == 720, "a show inside the interval books its rest")
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
        window.set(.visible)
        #expect(await rig.nextCall() == 1)
        #expect(try await rig.booking() == 120)
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
        _ = try await rig.booking()

        window.set(.hidden)
        rig.deadlines.advance(by: .seconds(10))
        rig.source.stop()
        rig.source.start()
        #expect(rig.source.runner == nil, "a hidden restart refreshed")
        #expect(!rig.isBooked)

        window.set(.visible)
        #expect(!rig.isBooked, "a show after a hidden restart booked the old interval's rest")
        #expect(await rig.nextCall() == 2, "a show after a hidden restart did not refresh at once")
        #expect(try await rig.booking() == 130)
        #expect(await rig.script.notificationETags.count == 2)
        rig.source.stop()
    }

    // MARK: p06-scheduler-344

    /// The poll runs while the app is hidden when no window tracking holds it (feature `hiddenPollPause` off):
    /// its booked refresh is then aligned on the app's node, and flexible again once the app shows.
    @Test(.timeLimit(.minutes(1))) func aHiddenAppAlignsTheBookedRefresh() async throws {
        let app = VisibilityNode(root: "app", own: .hidden)
        let rig = Rig(appNode: app)
        rig.source.start()
        #expect(await rig.nextCall() == 1)
        _ = try await rig.booking()
        #expect(rig.source.nextRefresh.plannedWake?.rule == .hidden, "a hidden app's poll woke on its own schedule")

        app.set(.visible)
        #expect(rig.source.nextRefresh.plannedWake?.rule == .flexible, "a shown app's poll stayed aligned")
        rig.source.stop()
    }
}
