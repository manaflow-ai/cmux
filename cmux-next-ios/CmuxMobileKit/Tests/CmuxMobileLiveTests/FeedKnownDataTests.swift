import Foundation
import Testing
import CmuxMobileModel
@testable import CmuxMobileFeed

@MainActor
@Suite struct FeedKnownDataTests {
    @Test func anEmptyLiveReadIsKnownAndNotifiesOnce() {
        let store = FeedStore(items: [])
        var notifications = 0
        store.onKnownData = { notifications += 1 }

        #expect(!store.hasKnownData)
        store.markKnown()
        store.markKnown()

        #expect(store.hasKnownData)
        #expect(notifications == 1)
    }

    @Test func anAccountArchiveRemembersAnEmptyFeed() {
        let url = FileManager.default.temporaryDirectory.appending(path: "feed-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = FeedArchive(url: url)
        #expect(archive.loadIfPresent() == nil)
        archive.save([])
        #expect(archive.loadIfPresent()?.isEmpty == true)
    }
}

#if os(iOS)
import CmuxMobileTransport
@testable import CmuxMobileLive

@MainActor
extension FeedKnownDataTests {
    @Test func switchingTeamsFlushesTheLatestFeedRowsIntoTheOriginalArchive() {
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        ServiceStub.install(host: host) { _ in nil }
        let account = "feed-switch-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appending(path: "feed-switch-\(UUID().uuidString)")
        let store = AppStore(teams: [], activeTeamID: "team-a", workspaces: [], feed: [], tabMemory: .inMemory())
        let feed = FeedStore(items: [])
        let live = LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: account, deviceName: "iPhone", transport: .wireGuard,
            dialer: MockDialer(fail: false), feedStore: feed,
            snapshots: LiveSnapshotStore(directory: directory), watchesConnectivity: false)
        defer {
            live.stop()
            FeedArchive.removeAll(forAccount: account)
            try? FileManager.default.removeItem(at: directory)
        }

        live.restoreFeedForActiveTeam()
        let first = Self.item("first", at: .distantPast)
        let second = Self.item("second", at: Date(timeIntervalSince1970: 100))
        feed.replaceAll([first])
        feed.replaceAll([second, first])

        store.activeTeamID = "team-b"
        live.restoreFeedForActiveTeam()
        #expect(feed.items.isEmpty)
        #expect(FeedArchive.forAccount(account, teamID: "team-b").loadIfPresent() == nil)

        store.activeTeamID = "team-c"
        live.restoreFeedForActiveTeam()
        store.activeTeamID = "team-a"
        live.restoreFeedForActiveTeam()
        #expect(feed.items.map(\.id) == ["second", "first"])
    }
}
#endif

extension FeedKnownDataTests {
    @Test func teamArchivesStaySeparateAcrossSwitchAndRelaunch() {
        let account = "feed-team-\(UUID().uuidString)"
        let one = FeedArchive.forAccount(account, teamID: "team/one")
        let two = FeedArchive.forAccount(account, teamID: "team_two")
        let collisionLeft = FeedArchive.forAccount(account + "--b", teamID: "c")
        let collisionRight = FeedArchive.forAccount(account, teamID: "b--c")
        defer {
            FeedArchive.removeAll(forAccount: account)
            FeedArchive.removeAll(forAccount: account + "--b")
        }

        #expect(one.url != two.url)
        #expect(collisionLeft.url != collisionRight.url)
        collisionLeft.save([Self.item("left")])
        collisionRight.save([Self.item("right")])
        FeedArchive.removeAll(forAccount: account + "--b")
        #expect(collisionLeft.loadIfPresent() == nil)
        #expect(collisionRight.loadIfPresent()?.map(\.id) == ["right"])
        one.save([Self.item("team-one")])
        #expect(two.loadIfPresent() == nil)

        // A new store reading the same team archive (the relaunch path) gets
        // the old rows, while switching to the other team stays empty.
        #expect(FeedArchive.forAccount(account, teamID: "team/one").load().map(\.id) == ["team-one"])
        #expect(FeedArchive.forAccount(account, teamID: "team_two").loadIfPresent() == nil)
    }

    private static func item(_ id: String, at date: Date = Date()) -> FeedItem {
        FeedItem(id: id, kind: .finished, workspaceID: "w", tabID: "t", agentName: "agent", harness: "claude",
                 workspaceTitle: "workspace", markdown: "done", quote: nil, createdAt: date)
    }
}
