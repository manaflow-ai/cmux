import CmuxMobileTransport
import Foundation
import Observation
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

    /// The Mac's Unread toggle (its only filter): unread or marked unread, with no grid
    /// (MessagesLab's filtered list), pinned ones first in the list's order.
    @Test func unreadOnlyKeepsUnreadAndMarkedUnread() {
        let list = MacHomeList(MacHomeRow.rows(fromHomeInbox: Self.reply), unreadOnly: true)
        #expect(list.pinned.isEmpty)
        #expect(list.rows.map(\.id) == ["conv_chief", "conv_ops"])
    }

    /// Every pinned conversation is a tile, as on the Mac (no cap).
    @Test func everyPinIsATile() {
        let many: [[String: Any]] = (0..<12).map { i in
            ["id": "conv_\(i)", "kind": "chief", "name": "C\(i)", "unread": 0, "activity_at": "2026-10-21T08:00:00Z",
             "pinned": true, "pin_position": i, "marked_unread": false]
        }
        let list = MacHomeList(MacHomeRow.rows(fromHomeInbox: ["me": "user_local", "rows": many]))
        #expect(list.pinned.count == 12)
        #expect(list.rows.isEmpty)
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
            // A conversation's own requests (cmux.protocol/2 engine reads) get no answer here.
            guard let id = object["id"] as? String, let cmd = object["cmd"] as? String else { return [] }
            func ok(_ data: [String: Any]) -> Data { line(["id": id, "ok": true, "data": data]) }
            switch cmd {
            case "conversation-list":
                return [ok(["conversations": rows.map { ["id": $0["id"]!, "last_seq": 7, "participants": [
                    ["id": "user_local", "kind": "human"], ["id": $0["chief"] ?? "agent_codex", "kind": "agent"]]] }])]
            case "subscribe", "conversation-typing":
                return [ok([:])]
            case "conversation-snapshot":
                return [ok(["conversation": ["id": object["conversation"]!, "participants": []], "messages": []])]
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
@Suite(.timeLimit(.minutes(2))) struct MacHomeFeedTests {
    /// Waits until `condition` holds on the main actor, waking as the feed's observable
    /// state changes (``eventually``). The suite's time limit is the run's watchdog.
    func until(_ condition: @MainActor () -> Bool) async -> Bool {
        await eventually(condition)
    }

    // The wait tests below measure no time: each gives every wake-up but the one it
    // tests an hour, so only that one can end the wait within the suite's time limit.
    // A wall-clock bound failed when another suite held the main thread 25 s.

    /// A wait wakes on the change it watches, not on a tick or the watchdog.
    @Test func aWaitWakesOnTheChangeItWatches() async {
        let flag = WaitFlag()
        Task { flag.done = true }
        #expect(await eventually(watchdog: .seconds(3600), tick: .seconds(3600)) { flag.done })
    }

    /// The watchdog ends a wait whatever the tick.
    @Test func theWatchdogEndsAWaitWhateverTheTick() async {
        #expect(await !eventually(watchdog: .milliseconds(100), tick: .seconds(3600)) { false })
    }

    /// A wait cancelled before it starts ends at once: before, the loop ignored
    /// cancellation, so a timed-out wait kept its task group from finishing.
    @Test func aCancelledWaitEnds() async {
        let wait = Task { await eventually(watchdog: .seconds(3600), tick: .seconds(3600)) { false } }
        wait.cancel()
        #expect(await wait.value == false)
    }

    /// A wait cancelled while it is suspended (its condition checked, waiting on a
    /// change or a tick) ends at once too: the cancellation wakes it.
    @Test func aWaitCancelledWhileSuspendedEnds() async {
        let checks = CheckCount()
        let wait = Task {
            await eventually(watchdog: .seconds(3600), tick: .seconds(3600)) { checks.count += 1; return false }
        }
        // Checked once: it is now suspended until a change, a tick or a cancel.
        #expect(await eventually { checks.count > 0 })
        wait.cancel()
        #expect(await wait.value == false)
    }

    /// Time the main thread is held does not use up a wait: the work it waits on was
    /// held too. Before, a wait that woke past its wall-clock deadline gave up on its
    /// first look, before that work had its turn (the full kit held the main thread
    /// over a minute, and four Chief waits failed that way at once).
    @Test func aHeldMainThreadDoesNotUseUpAWait() async {
        let flag = WaitFlag()
        Task {
            // Starts once the wait below is asleep on a tick, so the tick runs out during
            // the hold: hold the main thread past its watchdog, then finish a few
            // main-actor turns after the wait gets its next look.
            try? await Task.sleep(for: .milliseconds(50))
            holdTheMainThread(seconds: 0.5)
            Task {
                await Task.yield()
                await Task.yield()
                flag.done = true
            }
        }
        #expect(await eventually(watchdog: .milliseconds(200)) { flag.done })
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

    /// The Mac's event alone (no request from the phone) reads the list again.
    @Test func aNewMessageOnTheMacReadsTheListAgain() async throws {
        let owner = FakeHomeOwner()
        let link = PushLink { request in owner.respond(request) }
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-1")
        #expect(await until { feed.rows?.count == 4 })
        let reads = owner.inboxReads
        link.push(owner.post(in: "conv_old", preview: "Back again"))
        #expect(await until { feed.rows?.first { $0.id == "conv_old" }?.preview == "Back again" })
        #expect(owner.inboxReads > reads)
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
        // The rows show the pin at once; the write goes out from its own task.
        #expect(await until { !owner.sent("conversation-inbox-op").isEmpty })
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

    /// A list channel that could not open is opened again by the next refresh, on the same link.
    @Test func aFailedOpenIsTriedAgain() async throws {
        let owner = FakeHomeOwner()
        let link = PushLink { request in owner.respond(request) }
        link.failNextOpen = true
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-1")
        #expect(feed.problem != nil)
        #expect(feed.rows == nil)
        feed.refresh()
        #expect(await until { feed.rows?.count == 4 })
        #expect(feed.problem == nil)
    }

    /// The Mac Chief's row is known from the owner's list before its session finds it.
    @Test func theMacChiefsRowIsNamedByTheList() async throws {
        let owner = FakeHomeOwner()
        let feed = MacHomeFeed()
        await feed.connect(link: MockMacLink { _, request in owner.respond(request) }, macID: "mac-1")
        #expect(await until { feed.rows?.count == 4 })
        #expect(feed.macChiefID == "conv_chief")
    }

    /// A conversation opened from Home survives the list channel reopening on the same
    /// link; a new link closes it and tells its screen to ask again.
    @Test func openedConversationsFollowTheLink() async throws {
        let owner = FakeHomeOwner()
        let link = PushLink { request in owner.respond(request) }
        let feed = MacHomeFeed()
        await feed.connect(link: link, macID: "mac-1")
        #expect(await until { feed.rows?.count == 4 })
        let route = MacConversationRoute(conversationID: "conv_ops", chief: nil, title: "Ops")
        let first = try await feed.session(for: route)
        #expect(try await feed.session(for: route) === first)
        #expect(first.identity.chiefID == "agent_codex")
        let epoch = feed.sessionEpoch
        await feed.connect(link: PushLink { request in owner.respond(request) }, macID: "mac-1")
        #expect(feed.sessionEpoch == epoch + 1)
        #expect(try await feed.session(for: route) !== first)
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

/// A link whose channels answer each request through `respond` and can be sent an
/// event at any time (`push`), as the Mac's owner does.
final class PushLink: MacLink, @unchecked Sendable {
    let transport: TransportKind = .webRTC
    let states: AsyncStream<LinkState>
    private let respond: @Sendable (Data) -> [Data]
    private let lock = NSLock()
    private var channels: [PushChannel] = []
    private var nextID: UInt32 = 1
    var failNextOpen = false

    init(respond: @escaping @Sendable (Data) -> [Data]) {
        self.respond = respond
        states = AsyncStream { $0.yield(.connected(.webRTC, .direct, rttMillis: 1)) }
    }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        try lock.withLock {
            if failNextOpen {
                failNextOpen = false
                throw LinkError(code: "closed", message: "daemon channel closed")
            }
            defer { nextID += 2 }
            let channel = PushChannel(id: nextID, respond: respond)
            channels.append(channel)
            return channel
        }
    }

    func openInputChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        try await openChannel(service: service, args: args)
    }

    func ping() async throws -> UInt32 { 1 }
    func close() async {}
    var connectedPath: LinkPathKind? { .direct }

    /// One event line to every open channel.
    func push(_ line: Data) {
        for channel in lock.withLock({ channels }) { channel.deliver(line) }
    }
}

/// Set by a main-actor task in the wait tests; observable, as the feed is.
@MainActor @Observable final class WaitFlag {
    var done = false
}

/// Blocks the calling thread: synchronous, as a UIKit suite holding the main thread is.
func holdTheMainThread(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

/// How often a wait checked its condition: plain state, so counting never wakes it.
@MainActor final class CheckCount {
    var count = 0
}

final class PushChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32
    private let respond: @Sendable (Data) -> [Data]
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.AsyncIterator

    init(id: UInt32, respond: @escaping @Sendable (Data) -> [Data]) {
        self.id = id
        self.respond = respond
        (stream, continuation) = AsyncStream.makeStream()
        iterator = stream.makeAsyncIterator()
    }

    func deliver(_ line: Data) { continuation.yield(line) }
    func send(_ data: Data) async throws { for reply in respond(data) { continuation.yield(reply) } }
    func receive() async throws -> Data? { await iterator.next() }
    func close(code: String, reason: String) async { continuation.finish() }
}
