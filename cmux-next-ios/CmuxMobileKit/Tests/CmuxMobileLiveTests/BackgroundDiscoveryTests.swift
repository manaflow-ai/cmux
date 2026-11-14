import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// Mac discovery (`GET /me/macs`) per simulated hour on a virtual clock: none while
/// the app is in the background, and a backoff (not a 4 s poll for ever) while the
/// active team has no online Mac. Leo, 2026-11-14: "I want us to also look at if we
/// can decrease battery drain/ram on iOS app".
@MainActor
@Suite struct BackgroundDiscoveryTests {
    static let hour: Duration = .seconds(3600)

    @MainActor final class Rig {
        let clock = LinkTestClock()
        var looks = 0
        var online = false
        lazy var poll = MacDiscoveryPoll(clock: clock)

        func start() {
            poll.start { [unowned self] in
                looks += 1
                return online
            }
        }

        /// Lets the poll's task reach its next sleep (or end).
        func settle() async {
            for _ in 0..<200 where clock.nextDeadline == nil { await Task.yield() }
            for _ in 0..<20 { await Task.yield() }
        }

        /// Moves virtual time forward by `duration`, one sleeper deadline at a time.
        func run(for duration: Duration) async {
            let end = clock.now.advanced(by: duration)
            while true {
                await settle()
                guard let next = clock.nextDeadline, next <= end else { break }
                clock.advance(by: clock.now.duration(to: next))
            }
            let rest = clock.now.duration(to: end)
            if rest > .zero { clock.advance(by: rest) }
            await settle()
        }

        func finish() {
            poll.stop()
            clock.stop()
        }
    }

    @Test func noDiscoveryRequestsInABackgroundHour() async {
        for online in [false, true] {
            let rig = Rig()
            rig.online = online
            rig.start()
            await rig.settle()
            #expect(rig.looks == 1)
            rig.poll.pause()
            await rig.run(for: Self.hour)
            let background = rig.looks - 1
            print("bg-quiet: discovery requests per background hour (Mac online: \(online)): \(background)")
            #expect(background == 0)
            #expect(!rig.poll.isRunning)
            // Back in front: it looks at once, so the list is as fresh as before.
            rig.poll.resume()
            await rig.settle()
            #expect(rig.looks == 2)
            #expect(rig.poll.isRunning)
            rig.finish()
        }
    }

    @Test func noMacOnlineBacksOffToTheIdleCadence() async {
        let rig = Rig()
        rig.start()
        await rig.run(for: Self.hour)
        print("bg-quiet: discovery requests per foreground hour with no Mac online: \(rig.looks)")
        // 15 looks 4 s apart (someone setting up a Mac), then 8 s, 16 s and every 30 s:
        // at t = 0, 4, ..., 56, 60, 68, 84, then 114 + 30k up to 3594.
        #expect(rig.looks == 135)
        rig.finish()
    }

    @Test func aMacOnlineKeepsTheIdleCadence() async {
        let rig = Rig()
        rig.online = true
        rig.start()
        await rig.run(for: Self.hour)
        #expect(rig.looks == 121)
        rig.finish()
    }

    @Test func aWakeLooksAtOnceAndRestartsTheFastWait() async {
        let rig = Rig()
        rig.start()
        await rig.run(for: .seconds(300))
        let before = rig.looks
        rig.poll.wake()
        await rig.settle()
        #expect(rig.looks == before + 1)
        #expect(rig.clock.nextDeadline.map { rig.clock.now.duration(to: $0) } == MacDiscoveryPoll.waitingPoll)
        rig.finish()
    }

    @Test func aPausedPollStartedInTheBackgroundWaitsForTheForeground() async {
        let rig = Rig()
        rig.poll.pause()
        rig.start()
        await rig.run(for: Self.hour)
        #expect(rig.looks == 0)
        rig.poll.resume()
        await rig.settle()
        #expect(rig.looks == 1)
        rig.finish()
    }

    @Test func backoffSchedule() {
        #expect(MacDiscoveryPoll.delay(waitingLooks: 0) == .seconds(30))
        #expect(MacDiscoveryPoll.delay(waitingLooks: 1) == .seconds(4))
        #expect(MacDiscoveryPoll.delay(waitingLooks: 15) == .seconds(4))
        #expect(MacDiscoveryPoll.delay(waitingLooks: 16) == .seconds(8))
        #expect(MacDiscoveryPoll.delay(waitingLooks: 17) == .seconds(16))
        #expect(MacDiscoveryPoll.delay(waitingLooks: 18) == .seconds(30))
        #expect(MacDiscoveryPoll.delay(waitingLooks: 10_000) == .seconds(30))
    }
}

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
@MainActor
@Suite(.timeLimit(.minutes(2))) struct BackgroundDiscoveryCoordinatorTests {
    @Test func backgroundStopsDiscoveryAndForegroundRestartsIt() async {
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        // No answers: requests stay open, so only the lifecycle calls change anything.
        ServiceStub.install(host: host) { _ in nil }
        let clock = LinkTestClock()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-bg-quiet-\(UUID().uuidString)")
        let live = LiveCoordinator(
            store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory()),
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: "user-\(UUID().uuidString)", deviceName: "iPhone", transport: .wireGuard, dialer: MockDialer(fail: false),
            feedStore: FeedStore(items: []), snapshots: LiveSnapshotStore(directory: directory), clock: clock,
            watchesConnectivity: false
        )
        defer {
            live.stop()
            clock.stop()
        }
        live.applyAccountTeams([AppStore.AccountTeam(id: "t1", name: "One")], selectedID: "t1")
        #expect(live.discovery.isRunning)
        live.background()
        #expect(!live.discovery.isRunning)
        live.foreground()
        #expect(live.discovery.isRunning)
    }
}
#endif
