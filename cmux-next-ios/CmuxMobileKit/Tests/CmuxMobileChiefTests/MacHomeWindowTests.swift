import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileChief

/// Leo, 2026-11-10: "to load in my God sessions, it needs to be the exact same, or I mean,
/// close enough to the exact same as the small sessions." Home reads its first screen as a
/// window of the Mac's list, the rest behind it, and one row per event
/// (cmux-next-ios/design/instant-perf.md); an older host still gets the whole list.
@Suite struct MacHomeWindowTests {
    static func row(_ id: String, pinned: Bool = false, unread: Int = 0, preview: String = "hi") -> MacHomeRow {
        MacHomeRow(wire: ["id": id, "kind": "direct", "name": "Name \(id)", "unread": unread, "preview": preview,
                          "activity_at": "2026-10-12T09:41:07.123Z", "pinned": pinned])!
    }

    static func wire(_ id: String, index: Int? = nil, preview: String = "hi") -> [String: Any] {
        var row: [String: Any] = ["id": id, "kind": "direct", "name": "Name \(id)", "unread": 0, "preview": preview,
                                  "activity_at": "2026-10-12T09:41:07.123Z", "pinned": false]
        if let index { row["index"] = index }
        return row
    }

    @Test func aReplyIsTheWholeListAWindowOrTheNamedRows() throws {
        let all = MacHomeReply(homeInbox: ["rows": [Self.wire("conv_a")]])
        #expect(all == .all([Self.row("conv_a")]))
        let window = MacHomeReply(homeInbox: ["rows": [Self.wire("conv_a")], "offset": 0, "total": 5_000])
        #expect(window == .window([Self.row("conv_a")], offset: 0, total: 5_000))
        let some = MacHomeReply(homeInbox: ["rows": [Self.wire("conv_b", index: 7)], "total": 5_000])
        #expect(some == .named([MacHomeRows.Found(index: 7, row: Self.row("conv_b"))], total: 5_000, order: nil))
        // A host's refusal reads as one, so the feed can fall back.
        let refused = try JSONSerialization.data(withJSONObject: ["id": "m1", "ok": false,
                                                                  "error": ["code": "forbidden", "message": "home-inbox: limit is not accepted from a phone"]])
        #expect(throws: LinkError(code: "refused", message: "home-inbox: limit is not accepted from a phone")) {
            try MacHomeReply(line: refused)
        }
    }

    @Test func aRowThatKeptItsPlaceIsReplacedThere() {
        var rows = ["conv_a", "conv_b", "conv_c"].map { Self.row($0) }
        let changed = Self.row("conv_b", preview: "new")
        let inPlace = MacHomeRows.apply([.init(index: 1, row: changed)], asked: ["conv_b"], complete: true, to: &rows)
        #expect(inPlace == [1])
        #expect(rows.map(\.preview) == ["hi", "new", "hi"])
        // The same row again changes nothing.
        #expect(MacHomeRows.apply([.init(index: 1, row: changed)], asked: ["conv_b"], complete: true, to: &rows) == [])
    }

    @Test func aRowThatMovedOrLeftIsPlacedByItsIndex() {
        var rows = ["conv_a", "conv_b", "conv_c"].map { Self.row($0) }
        // A new message moves conv_c to the top.
        #expect(MacHomeRows.apply([.init(index: 0, row: Self.row("conv_c", preview: "new"))], asked: ["conv_c"],
                                  complete: true, to: &rows) == nil)
        #expect(rows.map(\.id) == ["conv_c", "conv_a", "conv_b"])
        // One the owner no longer lists leaves; a new one comes in at its place.
        #expect(MacHomeRows.apply([.init(index: 1, row: Self.row("conv_new"))], asked: ["conv_a", "conv_new"],
                                  complete: true, to: &rows) == nil)
        #expect(rows.map(\.id) == ["conv_c", "conv_new", "conv_b"])
        // With only the first window loaded, a row placed past it waits for the whole list.
        var top = ["conv_a", "conv_b"].map { Self.row($0) }
        _ = MacHomeRows.apply([.init(index: 40, row: Self.row("conv_far"))], asked: ["conv_far"], complete: false, to: &top)
        #expect(top.map(\.id) == ["conv_a", "conv_b"])
    }

    /// One row's change patches Home's list in place; a pin change or a filter builds it again.
    @Test func theMemoPatchesARowThatChangedInPlace() {
        var rows = [Self.row("conv_p", pinned: true), Self.row("conv_a"), Self.row("conv_b")]
        let memo = MacHomeList.Memo()
        _ = memo.list(rows, query: "", unreadOnly: false, version: .init(rows: 1))
        // The same version is the same list, with no comparison of rows.
        _ = memo.list(rows, query: "", unreadOnly: false, version: .init(rows: 1))
        #expect(memo.builds == 1)
        let revision = memo.revision

        rows[2] = Self.row("conv_b", unread: 3, preview: "new")
        let patched = memo.list(rows, query: "", unreadOnly: false, version: .init(rows: 2),
                                change: .init(revision: 2, indices: [2]))
        #expect(memo.builds == 1 && memo.patches == 1)
        #expect(patched == MacHomeList(rows))
        #expect(memo.revision != revision)

        // A change it did not see (version 3 skipped) is built, never patched.
        rows[1] = Self.row("conv_a", preview: "later")
        let built = memo.list(rows, query: "", unreadOnly: false, version: .init(rows: 4),
                              change: .init(revision: 4, indices: [1]))
        #expect(memo.builds == 2)
        #expect(built == MacHomeList(rows))

        // A row that changed its pin moves between the grid and the rows: built again.
        rows[1] = Self.row("conv_a", pinned: true)
        let moved = memo.list(rows, query: "", unreadOnly: false, version: .init(rows: 5),
                              change: .init(revision: 5, indices: [1]))
        #expect(memo.builds == 3)
        #expect(moved == MacHomeList(rows))

        // Under a search the list is built from every row.
        let found = memo.list(rows, query: "conv_b", unreadOnly: false, version: .init(rows: 5))
        #expect(found.rows.map(\.id) == ["conv_b"])
    }

    @MainActor
    @Test func keptRowsAreBoundedAndGoAtSignOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "home-rows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MacHomeRowsCache(directory: directory, rowLimit: 3, writeDelay: .never)
        let key = MacHomeRowsCache.key(account: "user_1", macID: "mac-1")
        cache.save(key, rows: (0..<10).map { Self.row("conv_\($0)") })
        #expect(cache.cached(key)?.map(\.id) == ["conv_0", "conv_1", "conv_2"])
        cache.flush()
        // A new run reads them from disk.
        let again = MacHomeRowsCache(directory: directory, rowLimit: 3)
        #expect(await again.load(key)?.count == 3)
        // Another account's key holds none of them.
        #expect(await again.load(MacHomeRowsCache.key(account: "user_2", macID: "mac-1")) == nil)
        again.removeAll()
        again.flush()
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }
}

/// The feed over a host that windows, one that refuses windows (older), and one that ignores them.
@MainActor
@Suite(.timeLimit(.minutes(2))) struct MacHomeWindowFeedTests {
    @Test func theFirstScreenIsAWindowAndTheWholeListFollows() async throws {
        let owner = FakeHomeOwner(windows: .honors)
        let feed = MacHomeFeed(firstWindow: 2)
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { feed.isComplete })
        #expect(feed.rows?.map(\.id) == ["conv_build", "conv_chief", "conv_ops", "conv_old"])
        let reads = owner.sent("home-inbox")
        #expect(reads.first?["limit"] as? Int == 2)
        #expect(reads.count >= 2)
        #expect(reads.dropFirst().allSatisfy { $0["limit"] == nil && $0["ids"] == nil })
    }

    /// An event reads its own row, placed where the owner now lists it.
    @Test func anEventReadsOnlyItsRow() async throws {
        let owner = FakeHomeOwner(windows: .honors)
        let link = PushLink { request in owner.respond(request) }
        let feed = MacHomeFeed(firstWindow: 2)
        await feed.connect(link: link, macID: "mac-1")
        #expect(await eventually { feed.isComplete })
        let before = owner.sent("home-inbox").count
        link.push(owner.post(in: "conv_old", preview: "Back again"))
        #expect(await eventually { feed.rows?.first { $0.id == "conv_old" }?.preview == "Back again" })
        let after = owner.sent("home-inbox").dropFirst(before)
        #expect(after.count == 1)
        #expect(after.first?["ids"] as? [String] == ["conv_old"])
        #expect(MacHomeList(feed.rows ?? []).rows.map(\.id) == ["conv_old", "conv_ops"])
        #expect(feed.problem == nil)
    }

    /// An older host refuses the window: the whole list, as before, and no problem shown.
    @Test func aHostWithoutWindowsGetsTheWholeList() async throws {
        let owner = FakeHomeOwner(windows: .refuses)
        let link = PushLink { request in owner.respond(request) }
        let feed = MacHomeFeed(firstWindow: 2)
        await feed.connect(link: link, macID: "mac-1")
        #expect(await eventually { feed.isComplete && feed.rows?.count == 4 })
        #expect(feed.problem == nil)
        let reads = owner.sent("home-inbox")
        #expect(reads.first?["limit"] as? Int == 2)
        #expect(reads.dropFirst().first.map { $0["limit"] == nil } == true)
        // Its events read the whole list too (never `ids`, which it would refuse).
        let before = reads.count
        link.push(owner.post(in: "conv_old", preview: "Back again"))
        #expect(await eventually { feed.rows?.first { $0.id == "conv_old" }?.preview == "Back again" })
        #expect(owner.sent("home-inbox").dropFirst(before).allSatisfy { $0["ids"] == nil && $0["limit"] == nil })
    }

    /// Search and Unread run over every row once the whole list is in, not only the window.
    @Test func searchAndUnreadCoverRowsPastTheFirstWindow() async throws {
        let owner = FakeHomeOwner(windows: .honors)
        let feed = MacHomeFeed(firstWindow: 1)
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { feed.isComplete })
        let rows = feed.rows ?? []
        #expect(MacHomeList(rows, query: "Old").rows.map(\.id) == ["conv_old"])
        #expect(MacHomeList(rows, unreadOnly: true).rows.map(\.id) == ["conv_chief", "conv_ops"])
        #expect(MacHomeList(rows).pinned.map(\.id) == ["conv_build", "conv_chief"])
    }

    /// Four plain rows, newest first, as the owner lists them.
    nonisolated(unsafe) static let plainRows: [[String: Any]] = ["conv_a", "conv_b", "conv_c", "conv_d"].map { id in
        ["id": id, "owner": "local", "kind": "direct", "name": "Name \(id)", "unread": 0, "preview": "hi",
         "activity_at": "2026-10-12T09:41:07.123Z", "pinned": false, "marked_unread": false, "muted": false]
    }

    nonisolated static func ids(in request: Data) -> [String]? {
        ((try? JSONSerialization.jsonObject(with: request.dropLast())) as? [String: Any])?["ids"] as? [String]
    }

    /// Two moves whose reads cross: C's read is answered after D also moved, so C's index is
    /// against a list where D already leads. The phone's order digest catches it and reads
    /// the whole list, so it ends in the owner's order (not [D, A, C, B]).
    @Test func crossedMovesEndInTheOwnersOrder() async throws {
        let owner = FakeHomeOwner(windows: .honors, rows: Self.plainRows)
        let raced = RaceFlag()
        let link = PushLink { request in
            guard Self.ids(in: request) == ["conv_c"], raced.take() else { return owner.respond(request) }
            // The owner takes D's message before it answers C's read; D's event comes after.
            let dMoved = owner.post(in: "conv_d", preview: "d")
            return owner.respond(request) + [dMoved]
        }
        let feed = MacHomeFeed(firstWindow: 2)
        await feed.connect(link: link, macID: "mac-1")
        #expect(await eventually { feed.isComplete })
        link.push(owner.post(in: "conv_c", preview: "c"))
        #expect(await eventually { feed.rows?.map(\.id) == ["conv_d", "conv_c", "conv_a", "conv_b"] })
        #expect(owner.order == ["conv_d", "conv_c", "conv_a", "conv_b"])
        #expect(feed.rows?.map(\.preview) == ["d", "c", "hi", "hi"])
    }

    /// A row's event during a pending write is read again once the write is answered, not
    /// dropped: the write's own row and the skipped one both come back.
    @Test func aRowChangedDuringAWriteIsReadAfterIt() async throws {
        let owner = FakeHomeOwner(windows: .honors)
        let held = HeldReply()
        let link = PushLink { request in
            let object = (try? JSONSerialization.jsonObject(with: request.dropLast())) as? [String: Any]
            if object?["cmd"] as? String == "conversation-op", let id = object?["id"] as? String {
                _ = owner.respond(request)
                held.hold(owner.line(["id": id, "ok": true, "data": ["rev": 10, "replayed": false]]))
                return []
            }
            return owner.respond(request)
        }
        let feed = MacHomeFeed(firstWindow: 2)
        await feed.connect(link: link, macID: "mac-1")
        #expect(await eventually { feed.isComplete })
        feed.markRead("conv_chief")
        #expect(await eventually { held.line != nil })
        // A message in another conversation while the read cursor write waits.
        let reads = owner.sent("home-inbox").count
        link.push(owner.post(in: "conv_old", preview: "Back again"))
        #expect(await eventually { owner.sent("home-inbox").count > reads })
        try link.push(#require(held.line))
        #expect(await eventually { feed.rows?.first { $0.id == "conv_old" }?.preview == "Back again" })
        #expect(MacHomeList(feed.rows ?? []).rows.map(\.id) == ["conv_old", "conv_ops"])
    }

    /// A Chief deleted on the Mac while the phone was away: the owner's list now fits in one
    /// window, and that window replaces the kept rows whole (the deleted row is not kept).
    @Test func aWholeWindowReplacesTheKeptRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "home-rows-gone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MacHomeRowsCache(directory: directory, writeDelay: .never)
        let key = MacHomeRowsCache.key(account: "user_1", macID: "mac-1")
        let owner = FakeHomeOwner(windows: .honors)
        cache.save(key, rows: MacHomeRow.rows(fromHomeInbox: MacHomeListTests.reply))
        owner.remove("conv_old")
        let feed = MacHomeFeed(rowsCache: cache, accountID: { "user_1" }, firstWindow: 20)
        feed.showKeptRows(of: "mac-1")
        #expect(feed.rows?.count == 4)
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { feed.isComplete && !feed.isShowingKeptRows })
        #expect(feed.rows?.map(\.id) == ["conv_build", "conv_chief", "conv_ops"])
        #expect(cache.cached(key)?.map(\.id) == ["conv_build", "conv_chief", "conv_ops"])
    }

    /// The rows this phone kept show before the Mac answers, then the Mac's own replace them.
    @Test func keptRowsShowUntilTheMacAnswers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "home-rows-feed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MacHomeRowsCache(directory: directory, writeDelay: .never)
        cache.save(MacHomeRowsCache.key(account: "user_1", macID: "mac-1"), rows: [MacHomeWindowTests.row("conv_kept")])
        let feed = MacHomeFeed(rowsCache: cache, accountID: { "user_1" }, firstWindow: 2)
        feed.showKeptRows(of: "mac-1")
        #expect(feed.rows?.map(\.id) == ["conv_kept"])
        #expect(feed.isShowingKeptRows)
        #expect(!feed.isComplete)
        let owner = FakeHomeOwner(windows: .honors)
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await eventually { feed.isComplete })
        #expect(feed.rows?.map(\.id) == ["conv_build", "conv_chief", "conv_ops", "conv_old"])
        #expect(!feed.isShowingKeptRows)
        #expect(cache.cached(MacHomeRowsCache.key(account: "user_1", macID: "mac-1"))?.count == 4)
        feed.discardForSignOut()
        #expect(cache.cached(MacHomeRowsCache.key(account: "user_1", macID: "mac-1")) == nil)
    }
}

/// Taken once, from any thread (a test's fake owner).
final class RaceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
}

/// A reply the test's fake owner holds back until the test sends it.
final class HeldReply: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Data?
    func hold(_ line: Data) { lock.withLock { held = line } }
    var line: Data? { lock.withLock { held } }
}
