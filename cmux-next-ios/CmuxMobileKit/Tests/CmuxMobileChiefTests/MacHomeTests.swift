import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileChief

/// User direction 2026-10-21: "I don't like the fact that there are Home rows
/// for agent chats, it's confusing. Home should be exact information parity
/// with macOS." The Mac's Home list is its conversation owner's `home-inbox`
/// rows (cmux-tui spec `home-inbox`; `HomeInboxSource` and `HomeSidebarModel`
/// on the Mac): the pinned grid in the owner's pin order, then every other
/// conversation newest first, each with its name, preview, time, unread state
/// and the Chief's typing. The phone reads the same rows from the same Mac
/// over the link and draws them as they come, so the two lists cannot drift.
@Suite struct MacHomeListTests {
    nonisolated(unsafe) static let reply: [String: Any] = ["me": "user_local", "cloud": "not_asked", "rows": [
        ["id": "conv_build", "owner": "local", "kind": "chief", "name": "Builder", "unread": 0, "activity_at": "2026-10-21T08:00:00Z",
         "preview": "**Done**: 3 tests", "chief": "agent_build", "chief_state": "working", "pinned": true, "pin_position": 5,
         "marked_unread": false, "muted": false],
        ["id": "conv_chief", "owner": "local", "kind": "chief", "name": "Chief", "unread": 2, "activity_at": "2026-10-21T10:00:00.250Z",
         "preview": "Shipped the fix", "chief": "agent_mux", "chief_state": "idle", "pinned": true, "pin_position": 9,
         "marked_unread": false, "muted": false],
        ["id": "conv_ops", "owner": "local", "kind": "channel", "name": "Ops", "unread": 0, "activity_at": "2026-10-21T09:30:00.000Z",
         "preview": "Deploy is green", "pinned": false, "marked_unread": true, "muted": false],
        ["id": "conv_old", "owner": "local", "kind": "chief", "name": "Old Chief", "unread": 0, "activity_at": "2026-10-19T09:30:00.000Z",
         "chief_state": "waiting", "pinned": false, "marked_unread": false, "muted": false],
    ]]

    @Test func rowsKeepTheOwnersOrderAndFields() throws {
        let rows = MacHomeRow.rows(fromHomeInbox: Self.reply)
        #expect(rows.map(\.id) == ["conv_build", "conv_chief", "conv_ops", "conv_old"])
        let chief = try #require(rows.first { $0.id == "conv_chief" })
        #expect(chief.kind == .chief)
        #expect(chief.name == "Chief")
        #expect(chief.unreadCount == 2)
        #expect(chief.isPinned)
        #expect(chief.activityAt == Date(timeIntervalSince1970: 1_792_576_800.25))
        // An agent's Markdown reads as the Mac's list draws it: no markers.
        #expect(rows[0].preview == "Done: 3 tests")
        #expect(rows[0].isWorking)
        #expect(!chief.isWorking)
        // Mark as Unread shows unread (at least one) until read.
        #expect(rows[2].unreadCount == 1)
        #expect(rows[3].chiefState == .waiting)
    }

    @Test func pinnedGridThenRowsAsOnTheMac() {
        let list = MacHomeList(MacHomeRow.rows(fromHomeInbox: Self.reply))
        #expect(list.pinned.map(\.id) == ["conv_build", "conv_chief"])
        #expect(list.rows.map(\.id) == ["conv_ops", "conv_old"])
    }

    /// The Mac's search: no pinned grid while searching, the matching pinned
    /// conversations lead the rows; a match is the name or the preview.
    @Test func searchFoldsThePinnedGridIntoTheRows() {
        let rows = MacHomeRow.rows(fromHomeInbox: Self.reply)
        let list = MacHomeList(rows, query: "  chief ")
        #expect(list.pinned.isEmpty)
        #expect(list.rows.map(\.id) == ["conv_chief", "conv_old"])
        #expect(MacHomeList(rows, query: "green").rows.map(\.id) == ["conv_ops"])
    }

    /// The Mac's Unread toggle (its only filter): unread or marked unread.
    @Test func unreadOnlyKeepsUnreadAndMarkedUnread() {
        let list = MacHomeList(MacHomeRow.rows(fromHomeInbox: Self.reply), unreadOnly: true)
        #expect(list.pinned.map(\.id) == ["conv_chief"])
        #expect(list.rows.map(\.id) == ["conv_ops"])
    }

    /// The pinned grid holds at most nine tiles, as the Mac's.
    @Test func pinnedGridHoldsNineTiles() {
        let many: [[String: Any]] = (0..<12).map { i in
            ["id": "conv_\(i)", "kind": "chief", "name": "C\(i)", "unread": 0, "activity_at": "2026-10-21T08:00:00Z",
             "pinned": true, "pin_position": i, "marked_unread": false]
        }
        let list = MacHomeList(MacHomeRow.rows(fromHomeInbox: ["me": "user_local", "rows": many]))
        #expect(list.pinned.count == 9)
        #expect(list.rows.map(\.id) == ["conv_9", "conv_10", "conv_11"])
    }
}

/// A fake Chief owner for Home: `conversation-list`, `home-inbox` and the
/// person's list state, which comes back as `conversation-inbox-changed`.
final class FakeHomeOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[String: Any]] = MacHomeListTests.reply["rows"] as! [[String: Any]]
    private(set) var commands: [[String: Any]] = []

    func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    var inboxReads: Int { lock.withLock { commands.filter { $0["cmd"] as? String == "home-inbox" }.count } }

    func sent(_ cmd: String) -> [[String: Any]] { lock.withLock { commands.filter { $0["cmd"] as? String == cmd } } }

    /// A Mac-side change: a new message in `conversation` (the Mac's list moves it up).
    func post(in conversation: String, preview: String) -> Data {
        lock.withLock {
            if let index = rows.firstIndex(where: { $0["id"] as? String == conversation }) {
                var row = rows.remove(at: index)
                row["preview"] = preview
                row["unread"] = (row["unread"] as? Int ?? 0) + 1
                rows.insert(row, at: rows.firstIndex { !($0["pinned"] as? Bool ?? false) } ?? rows.endIndex)
            }
        }
        return line(["event": "conversation-changed", "conversation": conversation, "rev": 9,
                     "change": ["kind": "message", "message": ["id": "msg_9", "seq": 9]]])
    }

    func respond(_ request: Data) -> [Data] {
        lock.withLock {
            let object = try! JSONSerialization.jsonObject(with: request.dropLast()) as! [String: Any]
            commands.append(object)
            let id = object["id"] as! String
            func ok(_ data: [String: Any]) -> Data { line(["id": id, "ok": true, "data": data]) }
            switch object["cmd"] as! String {
            case "conversation-list":
                return [ok(["conversations": rows.map { ["id": $0["id"]!, "last_seq": 7, "participants": [
                    ["id": "user_local", "kind": "human"], ["id": $0["chief"] ?? "agent_mux", "kind": "agent"]]] }])]
            case "subscribe":
                return [ok([:])]
            case "home-inbox":
                return [ok(["me": "user_local", "cloud": "not_asked", "rows": rows])]
            case "conversation-inbox-op":
                let conversation = object["conversation"] as! String
                let op = object["op"] as! [String: Any]
                guard let index = rows.firstIndex(where: { $0["id"] as? String == conversation }) else { return [] }
                if op["kind"] as? String == "inbox.pin" {
                    var row = rows.remove(at: index)
                    row["pinned"] = op["pinned"]
                    let pinnedCount = rows.filter { $0["pinned"] as? Bool ?? false }.count
                    rows.insert(row, at: (op["pinned"] as? Bool ?? false) ? pinnedCount : rows.endIndex)
                } else {
                    rows[index]["marked_unread"] = op["unread"]
                }
                let row = rows.first { $0["id"] as? String == conversation }!
                return [ok(["conversation": conversation, "participant": "user_local", "pinned": row["pinned"]!,
                            "marked_unread": row["marked_unread"]!]),
                        line(["event": "conversation-inbox-changed", "conversation": conversation, "participant": "user_local",
                              "pinned": row["pinned"]!, "marked_unread": row["marked_unread"]!])]
            case "conversation-op":
                return [ok(["rev": 10, "replayed": false])]
            default:
                return [line(["id": id, "ok": false, "error": "unknown command"])]
            }
        }
    }
}

@MainActor
@Suite struct MacHomeFeedTests {
    /// Waits (bounded) until `condition` holds on the main actor.
    func until(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        await within(.seconds(5)) {
            while await !condition() { await Task.yield() }
            return true
        } ?? false
    }

    @Test func readsTheMacsHomeListOverTheChiefChannel() async throws {
        let owner = FakeHomeOwner()
        let link = MockMacLink { _, request in owner.respond(request) }
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-1")
        #expect(await until { feed.rows?.count == 4 })
        #expect(feed.rows?.map(\.id) == ["conv_build", "conv_chief", "conv_ops", "conv_old"])
        #expect(feed.macID == "mac-1")
        // The scope first (the channel's filter learns it from the list), the local owner's rows only.
        let order = owner.commands.compactMap { $0["cmd"] as? String }
        #expect(order.prefix(3) == ["conversation-list", "subscribe", "home-inbox"])
        #expect(owner.sent("home-inbox").first?["owners"] as? [String] == ["local"])
    }

    @Test func aNewMessageOnTheMacReadsTheListAgain() async throws {
        let owner = FakeHomeOwner()
        let pending = PendingEvents()
        let link = MockMacLink { _, request in owner.respond(request) + pending.take() }
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-1")
        #expect(await until { feed.rows?.count == 4 })
        pending.add(owner.post(in: "conv_old", preview: "Back again"))
        // Any request lets the queued event through (the fake has no clock of its own).
        feed.refresh()
        #expect(await until { feed.rows?.first { $0.id == "conv_old" }?.preview == "Back again" })
        #expect(MacHomeList(feed.rows ?? []).rows.map(\.id) == ["conv_old", "conv_ops"])
    }

    /// Pin, Unpin, Mark as Unread and Mark as Read are the person's own list
    /// state on the Mac's owner, so the Mac's Home shows the same change.
    @Test func listActionsWriteTheMacsListState() async throws {
        let owner = FakeHomeOwner()
        let link = MockMacLink { _, request in owner.respond(request) }
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-1")
        #expect(await until { feed.rows?.count == 4 })

        feed.setPinned(true, "conv_ops")
        #expect(await until { MacHomeList(feed.rows ?? []).pinned.map(\.id) == ["conv_build", "conv_chief", "conv_ops"] })
        let pin = try #require(owner.sent("conversation-inbox-op").last)
        #expect(pin["conversation"] as? String == "conv_ops")
        #expect((pin["op"] as? [String: Any])?["kind"] as? String == "inbox.pin")
        #expect((pin["op"] as? [String: Any])?["position"] as? NSNumber != nil)

        feed.setMarkedUnread(true, "conv_old")
        #expect(await until { feed.rows?.first { $0.id == "conv_old" }?.unreadCount == 1 })

        // Mark as Read: the mark goes and the read cursor moves to the newest message.
        feed.markRead("conv_chief")
        #expect(await until { owner.sent("conversation-op").count == 1 })
        let read = try #require(owner.sent("conversation-op").first)
        #expect(read["conversation"] as? String == "conv_chief")
        #expect((read["op"] as? [String: Any])?["kind"] as? String == "read_cursor.set")
        #expect((read["op"] as? [String: Any])?["seq"] as? Int == 7)
    }

    /// Another Mac chosen: its own list, never the last Mac's rows.
    @Test func anotherMacStartsFromItsOwnList() async throws {
        let owner = FakeHomeOwner()
        let feed = MacHomeFeed()
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await until { feed.rows?.count == 4 })
        let other = MockMacLink { _, request in
            let object = try! JSONSerialization.jsonObject(with: request.dropLast()) as! [String: Any]
            var data = try! JSONSerialization.data(withJSONObject: ["id": object["id"]!, "ok": true, "data": [
                "conversations": [], "me": "user_local", "rows": [] as [Any]]])
            data.append(0x0A)
            return [data]
        }
        await feed.connect(link: other, macID: "mac-2")
        #expect(await until { feed.rows?.isEmpty == true })
        #expect(feed.macID == "mac-2")
    }
}

/// Events a test releases with the next reply.
final class PendingEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    func add(_ line: Data) { lock.withLock { lines.append(line) } }
    func take() -> [Data] { lock.withLock { defer { lines = [] }; return lines } }
}
