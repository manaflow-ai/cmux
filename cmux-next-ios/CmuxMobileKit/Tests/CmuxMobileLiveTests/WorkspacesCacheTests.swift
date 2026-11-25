import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

// The Workspaces list's on-device cache (LiveSnapshotStore): a cold launch paints the cached rows
// before any link, reading only each Mac's first screen, so a 5,000-workspace cache costs what a
// 100-workspace one does; a cache of another version or a corrupt one falls back to none, never a
// crash; the rest joins below the first screen without moving it; sign-out deletes it all.
// Leo, 2026-11-10: "your recent shit, like, should be fucking showing. And it should just be like,
// okay, we load, like, nigh instantly."

enum CacheFixture {
    static let mac = MacDevice(id: "m1", name: "Studio", isOnline: true)
    static let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// `count` workspaces in the Mac's sidebar order, the first 6 pinned (in reverse pin order),
    /// every other one in a group, activity times spread out.
    static func rows(_ count: Int) -> [Workspace] {
        let group = MacWorkspaceGroup(id: "g1", name: "Infra")
        return (0..<count).map { index in
            var ws = Workspace(id: "ws-\(index)", macID: mac.id, title: "workspace \(index)", directory: "/src/\(index % 9)",
                               tabs: [WorkspaceTab(id: "t\(index)", kind: .terminal, title: "zsh")],
                               lastActivityAt: savedAt.addingTimeInterval(-Double((index * 7_919) % 100_000)),
                               focusOrder: count - index)
            ws.isPinned = index < 6
            ws.pinIndex = ws.isPinned ? 5 - index : nil
            ws.sidebarIndex = index
            if !ws.isPinned, index % 2 == 0 { ws.group = group }
            return ws
        }
    }

    static func snapshot(_ rows: [Workspace]) -> LiveSnapshot {
        LiveSnapshot(teamID: "t1", teamName: "One", macs: [mac], linkedMacID: mac.id,
                     workspaces: [mac.id: .init(workspaces: rows, savedAt: savedAt)])
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func saved(_ count: Int, account: String = "user") -> (LiveSnapshotStore, URL) {
        let directory = directory()
        let store = LiveSnapshotStore(directory: directory)
        store.save(snapshot(rows(count)), accountID: account)
        store.flush()
        return (store, directory)
    }

    /// The ids the list shows first for a cached Mac (pins, then sidebar order).
    static func firstScreenIDs(_ rows: [Workspace], _ count: Int = 20) -> [String] {
        Array(LiveSnapshot.listOrder(rows).prefix(count).map(\.id))
    }
}

@Suite struct WorkspacesCacheStoreTests {
    @Test func firstScreenWorkIsTheSameForAGodCacheAsForASmallOne() throws {
        // Any list longer than one screen reads one screen's rows: 100 and 5,000 workspaces alike.
        let (small, smallDir) = CacheFixture.saved(100)
        let (god, godDir) = CacheFixture.saved(5_000)
        defer {
            try? FileManager.default.removeItem(at: smallDir)
            try? FileManager.default.removeItem(at: godDir)
        }
        let smallShot = try #require(small.loadFirstScreen(accountID: "user"))
        let godShot = try #require(god.loadFirstScreen(accountID: "user"))
        let smallRead = try #require(small.lastFirstScreenRead)
        let godRead = try #require(god.lastFirstScreenRead)
        #expect(godRead.rows <= LiveSnapshotStore.firstScreenRows * 2)
        #expect(Double(godRead.rows) <= 1.2 * Double(smallRead.rows), "god decodes \(godRead.rows) rows, small \(smallRead.rows)")
        #expect(Double(godRead.bytes) <= 1.2 * Double(smallRead.bytes), "god reads \(godRead.bytes) B, small \(smallRead.bytes) B")
        // The first screen is there, and the cache knows how many rows follow.
        #expect(godShot.workspaces["m1"]?.total == 5_000)
        #expect(godShot.workspaces["m1"]?.isComplete == false)
        let godRows = try #require(godShot.workspaces["m1"]?.workspaces)
        #expect(CacheFixture.firstScreenIDs(godRows) == CacheFixture.firstScreenIDs(CacheFixture.rows(5_000)))
        #expect(smallShot.workspaces["m1"]?.total == 100)
    }

    @Test func theRestJoinsBelowTheFirstScreen() async throws {
        let (store, directory) = CacheFixture.saved(5_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(store.loadFirstScreen(accountID: "user"))
        let rest = await store.loadRest(first, accountID: "user")
        let whole = try #require(rest["m1"])
        #expect(whole.isComplete && whole.workspaces.count == 5_000)
        #expect(Set(whole.workspaces.map(\.id)).count == 5_000)
        #expect(CacheFixture.firstScreenIDs(whole.workspaces, 40) == CacheFixture.firstScreenIDs(first.workspaces["m1"]?.workspaces ?? [], 40))
        #expect(store.load(accountID: "user")?.workspaces["m1"]?.workspaces.count == 5_000)
    }

    @Test func theCacheIsBounded() throws {
        let (store, directory) = CacheFixture.saved(LiveSnapshotStore.maxRowsPerMac + 700)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = try #require(store.load(accountID: "user")?.workspaces["m1"]?.workspaces)
        #expect(rows.count == LiveSnapshotStore.maxRowsPerMac)
        // The rows kept are the list's first ones.
        #expect(CacheFixture.firstScreenIDs(rows) == CacheFixture.firstScreenIDs(CacheFixture.rows(LiveSnapshotStore.maxRowsPerMac + 700)))
    }

    @Test func aCorruptOrOldCacheFallsBackToNone() throws {
        let directory = CacheFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LiveSnapshotStore(directory: directory)
        let account = directory.appending(path: "account-user", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)

        // Garbage.
        try Data("{\"format\":2,\"teamID\":".utf8).write(to: account.appending(path: "head.json"))
        #expect(store.loadFirstScreen(accountID: "user") == nil)
        #expect(!FileManager.default.fileExists(atPath: account.path), "a corrupt cache stays on disk")

        // Another version of the format, otherwise well formed.
        store.save(CacheFixture.snapshot(CacheFixture.rows(10)), accountID: "user")
        store.flush()
        let head = account.appending(path: "head.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: head)) as? [String: Any])
        object["format"] = LiveSnapshotStore.formatVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: head)
        #expect(store.loadFirstScreen(accountID: "user") == nil)
        #expect(!FileManager.default.fileExists(atPath: account.path))

        // The format-1 file (one JSON of the whole list) is not read, and goes.
        let legacy = directory.appending(path: "snapshot-user.json")
        try Data("{\"teamID\":\"t1\"}".utf8).write(to: legacy)
        #expect(store.loadFirstScreen(accountID: "user") == nil)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func aCorruptTailKeepsTheFirstScreen() async throws {
        let (store, directory) = CacheFixture.saved(500)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tail = directory.appending(path: "account-user/tail-m1.json")
        #expect(FileManager.default.fileExists(atPath: tail.path))
        try Data("not json".utf8).write(to: tail)
        let first = try #require(store.loadFirstScreen(accountID: "user"))
        let headRows = first.workspaces["m1"]?.workspaces.count ?? 0
        let rest = await store.loadRest(first, accountID: "user")
        #expect(rest["m1"]?.workspaces.count == headRows)
        #expect(rest["m1"]?.isComplete == true)
        #expect(!FileManager.default.fileExists(atPath: tail.path))
    }

    @Test func savingTheFirstScreenAloneKeepsTheTail() async throws {
        let (store, directory) = CacheFixture.saved(500)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A save before the rest was read (the link moved, the Mac not answered): the tail stays its.
        var first = try #require(store.loadFirstScreen(accountID: "user"))
        first.linkedMacID = nil
        store.save(first, accountID: "user")
        store.flush()
        #expect(store.load(accountID: "user")?.workspaces["m1"]?.workspaces.count == 500)
        #expect(store.load(accountID: "user")?.linkedMacID == nil)
    }

    @Test func aStaleReadLeavesANewerSavesTail() async throws {
        let (store, directory) = CacheFixture.saved(500)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Head A read; then the Mac answers and B is saved (a new tail token) before A's rest is read.
        let headA = try #require(store.loadFirstScreen(accountID: "user"))
        var rowsB = CacheFixture.rows(600)
        rowsB[100].title = "saved by B"
        store.save(CacheFixture.snapshot(rowsB), accountID: "user")
        store.flush()
        let rest = await store.loadRest(headA, accountID: "user")
        // A gets only its head (its tail is gone), and B's tail stays for B's head.
        #expect(rest["m1"]?.workspaces.count == headA.workspaces["m1"]?.workspaces.count)
        let whole = try #require(store.load(accountID: "user")?.workspaces["m1"]?.workspaces)
        #expect(whole.count == 600)
        #expect(whole.contains { $0.title == "saved by B" })
    }

    @Test func signOutDeletesTheCache() throws {
        let (store, directory) = CacheFixture.saved(500)
        defer { try? FileManager.default.removeItem(at: directory) }
        // What sign-out runs (`AccountSignOut`, `LiveCoordinator.forgetSnapshots`).
        store.removeAll()
        store.flush()
        #expect(store.loadFirstScreen(accountID: "user") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

// The coordinator is iOS-only: this runs in the iOS simulator test pass.
#if os(iOS)
@MainActor
@Suite(.serialized) struct WorkspacesColdLaunchTests {
    @Test func aColdLaunchPaintsTheCachedRowsWithNoLink() async throws {
        let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
        // The service never answers and every dial fails: nothing but the cache can paint.
        ServiceStub.install(host: host) { _ in ServiceStub.Reply(held: true) }
        let userID = "user-\(UUID().uuidString)"
        let directory = CacheFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshots = LiveSnapshotStore(directory: directory)
        let rows = CacheFixture.rows(5_000)
        snapshots.save(CacheFixture.snapshot(rows), accountID: userID)
        snapshots.flush()

        let store = AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
        let live = LiveCoordinator(
            store: store,
            api: LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" },
            identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: MockDialer(fail: true),
            feedStore: FeedStore(items: []), snapshots: snapshots)
        defer {
            live.stop()
            ServiceStub.release(host: host)
        }
        // Painted before any await: the first screen's rows, marked cached, and the count of all.
        let painted = store.workspaces
        #expect(!painted.isEmpty && painted.count <= LiveSnapshotStore.firstScreenRows * 2)
        #expect(CacheFixture.firstScreenIDs(painted) == CacheFixture.firstScreenIDs(rows))
        #expect(store.macDataPhase("m1").isStale)
        #expect(store.macData["m1"]?.count == 5_000)

        // The rest joins below without moving the first screen.
        for _ in 0..<5_000 where store.workspaces.count < 5_000 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(store.workspaces.count == 5_000)
        #expect(CacheFixture.firstScreenIDs(store.workspaces, 40) == CacheFixture.firstScreenIDs(painted, 40))
        #expect(store.macDataPhase("m1").isStale)
    }
}
#endif
