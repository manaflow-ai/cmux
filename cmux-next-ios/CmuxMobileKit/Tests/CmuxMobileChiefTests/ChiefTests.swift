import CmuxConversationCore
import CmuxMobileAgentChat
import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Observation
import Testing
@testable import CmuxMobileChief

@Suite struct MessagesStampTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func todayYesterdayWeekdayDate() {
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_791_800_000)
        let stamp = MessagesStamp(now: now, calendar: calendar, locale: locale)
        #expect(stamp.string(for: now.addingTimeInterval(-3600)).contains(":"))
        #expect(stamp.string(for: now.addingTimeInterval(-86_400)) == "Yesterday")
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        var weekday = Date.FormatStyle().weekday(.wide)
        weekday.calendar = calendar
        weekday.locale = locale
        weekday.timeZone = calendar.timeZone
        #expect(stamp.string(for: threeDaysAgo) == threeDaysAgo.formatted(weekday))
        #expect(!stamp.string(for: threeDaysAgo).contains("/"))
        #expect(stamp.string(for: now.addingTimeInterval(-30 * 86_400)).contains("/"))
    }
}

@Suite struct ChiefWireTests {
    let wire = ChiefWire(identity: .standard)

    @Test func tapbacksRoundTrip() {
        for (name, reaction) in ChiefWire.tapbacks {
            #expect(wire.reaction(kind: ["tapback": name]) == reaction)
            #expect(wire.wireKind(reaction)["tapback"] as? String == name)
        }
        #expect(wire.reaction(kind: ["emoji": "🔥"]) == .emoji("🔥"))
    }

    /// The owner writes milliseconds; Rust timestamps may carry micro- or
    /// nanoseconds, or none.
    @Test func datesParseAtEveryPrecision() throws {
        let base = try #require(wire.date("2026-10-12T09:41:07Z"))
        for text in ["2026-10-12T09:41:07.123Z", "2026-10-12T09:41:07.123456Z", "2026-10-12T09:41:07.123456789Z"] {
            let date = try #require(wire.date(text), "\(text)")
            #expect(abs(date.timeIntervalSince(base) - 0.123) < 0.001, "\(text)")
        }
        #expect(wire.date("2026-10-12T11:41:07.5+02:00").map { $0.timeIntervalSince(base) } == 0.5)
        #expect(wire.date("not a date") == nil)
    }

    @Test func messageMapsPartsReceiptsAndReactions() throws {
        let object: [String: Any] = [
            "id": "msg_1", "conversation": "conv_1", "seq": 4, "client_msg_id": "c1", "author": "user_local",
            "parts": [["type": "text", "text": "run the tests"], ["type": "work", "session": "s", "status": "running", "preview": "swift test"]],
            "created_at": "2026-10-12T09:41:07.123Z",
            "reactions": [["author": "agent_mux", "part_index": 0, "kind": ["tapback": "like"], "at": "2026-10-12T09:41:08.000Z"]],
        ]
        let read = try #require(wire.message(object, peerReadSeq: 4))
        #expect(read.text == "run the tests\nswift test (running)")
        #expect(read.delivery == .read(nil))
        #expect(read.reactions == [ConversationReactionMark(participantID: "agent_mux", reaction: .thumbsup)])
        #expect(read.sentAt.timeIntervalSince1970 > 1_791_000_000)
        #expect(wire.message(object, peerReadSeq: 3)?.delivery == .delivered)
    }
}

/// A fake cmux-tui daemon behind `MockMacLink`: the local conversation
/// owner's commands, plus Chief replying (typing, then a message) to each send.
final class FakeDaemon: @unchecked Sendable {
    private let lock = NSLock()
    /// The Mac's Home creates Chief; the phone only finds it.
    private var conversations: [[String: Any]] = [[
        "id": "conv_chief", "owner": "local", "title": "Chief",
        "participants": [["id": "user_local", "kind": "human", "display_name": "You"],
                         ["id": "agent_mux", "kind": "agent", "display_name": "Chief", "agent_class": "mux"]],
        "read_cursors": [:], "created_at": "2026-10-12T09:00:00.000Z", "updated_at": "2026-10-12T09:00:00.000Z",
    ]]
    private(set) var ops: [[String: Any]] = []

    init(chiefStarted: Bool = true) {
        if !chiefStarted { conversations = [] }
    }
    private var messages: [[String: Any]] = []
    private var rev = 0
    private(set) var commands: [String] = []
    /// `conversation-attachment-upload`: open uploads and stored bytes by hash.
    private var uploads: [String: (hash: String, bytes: Data)] = [:]
    private(set) var stored: [String: Data] = [:]
    private(set) var sentParts: [[[String: Any]]] = []

    func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private func summary() -> [String: Any] {
        var summary = conversations[0]
        summary["rev"] = rev
        summary["last_seq"] = messages.count
        return summary
    }

    private func message(author: String, text: String, client: String, parts: [[String: Any]]? = nil) -> [String: Any] {
        ["id": "msg_\(messages.count + 1)", "conversation": "conv_chief", "seq": messages.count + 1, "client_msg_id": client,
         "author": author, "parts": parts ?? [["type": "text", "text": text]], "created_at": "2026-10-12T09:41:07.000Z", "reactions": []]
    }

    /// A photo Chief sent earlier, stored by the owner (not by this client).
    func seedChiefPhoto(_ bytes: Data) -> String {
        lock.withLock {
            let hash = "chiefphoto"
            stored[hash] = bytes
            messages.append(message(author: "agent_mux", text: "", client: "seed-photo", parts: [[
                "type": "attachment", "hash": hash, "name": "chart.png", "mime_type": "image/png",
                "byte_count": bytes.count, "width": 4, "height": 3,
            ]]))
            return hash
        }
    }

    /// The approval the last `question.answer` carried.
    private(set) var lastApproval: [String: Any]?
    /// Event lines sent after the next reply (a Mac-side change).
    private var queued: [Data] = []
    /// When set, queued events wait for a reply to this command (an event
    /// that reaches the phone after a page that already includes its change).
    private var queuedUntil: String?

    func queue(_ event: [String: Any]) {
        lock.withLock { queued.append(line(event)) }
    }

    /// Chief posts `text` on its own (a turn's end), delivered as a
    /// `conversation-changed` event after the next reply (with `deliverOn`,
    /// after the next reply to that command).
    func queueChiefMessage(_ text: String, deliverOn command: String? = nil) {
        lock.withLock {
            let posted = message(author: "agent_mux", text: text, client: "chief-\(messages.count + 1)")
            messages.append(posted)
            rev += 1
            queued.append(line(["event": "conversation-changed", "conversation": "conv_chief", "rev": rev,
                                "transaction": NSNull(), "change": ["kind": "message", "message": posted]]))
            queuedUntil = command
        }
    }

    /// Chief retracts message `id`: a `message-updated` event after the next reply.
    func queueRetraction(of id: String) {
        lock.withLock {
            guard let index = messages.firstIndex(where: { $0["id"] as? String == id }) else { return }
            messages[index]["retracted_at"] = "2026-10-12T09:45:00.000Z"
            rev += 1
            queued.append(line(["event": "conversation-changed", "conversation": "conv_chief", "rev": rev,
                                "transaction": NSNull(), "change": ["kind": "message-updated", "message": messages[index]]]))
        }
    }

    /// Chief asks to allow a command (part 1 of its message).
    func seedChiefQuestion() -> String {
        lock.withLock {
            let question: [String: Any] = [
                "type": "question", "harness": "chief", "session": "chief",
                "items": [["id": "allow", "prompt": "Allow cargo test?", "multi_select": false, "allows_other": false,
                           "options": [["id": "allow", "label": "Allow"], ["id": "deny", "label": "Don't Allow"]]]],
                "state": ["kind": "pending"],
            ]
            let asked = message(author: "agent_mux", text: "", client: "seed-question",
                                parts: [["type": "text", "text": "Want me to allow it?"], question])
            messages.append(asked)
            return asked["id"] as! String
        }
    }

    func respond(_ request: Data) -> [Data] {
        let replies = respondNow(request)
        let cmd = (try? JSONSerialization.jsonObject(with: request.dropLast()) as? [String: Any])?["cmd"] as? String
        let events: [Data] = lock.withLock {
            if let queuedUntil, queuedUntil != cmd { return [] }
            defer { queued = []; queuedUntil = nil }
            return queued
        }
        return replies + events
    }

    private func respondNow(_ request: Data) -> [Data] {
        lock.withLock {
            let object = try! JSONSerialization.jsonObject(with: request.dropLast()) as! [String: Any]
            let id = object["id"] as! String
            let cmd = object["cmd"] as! String
            commands.append(cmd)
            func ok(_ data: [String: Any]) -> Data { line(["id": id, "ok": true, "data": data]) }
            switch cmd {
            case "conversation-list":
                return [ok(["conversations": conversations])]
            case "conversation-create":
                conversations = [[
                    "id": "conv_chief", "owner": "local", "title": object["title"]!, "participants": object["participants"]!,
                    "read_cursors": [:], "created_at": "2026-10-12T09:00:00.000Z", "updated_at": "2026-10-12T09:00:00.000Z",
                ]]
                rev = 1
                return [ok(["conversation": summary(), "replayed": false])]
            case "subscribe":
                return [ok([:])]
            case "conversation-snapshot":
                let tail = object["tail"] as! Int
                return [ok(["conversation": summary(), "messages": Array(messages.suffix(tail))])]
            case "conversation-history":
                let before = object["before_seq"] as! Int
                return [ok(["messages": messages.filter { ($0["seq"] as! Int) < before }])]
            case "conversation-typing":
                return [ok([:])]
            case "conversation-attachment-upload":
                switch object["op"] as! String {
                case "begin":
                    let upload = "up_\(uploads.count + 1)"
                    uploads[upload] = (object["sha256"] as! String, Data())
                    return [ok(["upload": upload, "needs": ["original"], "stored": NSNull()])]
                case "chunk":
                    let upload = object["upload"] as! String
                    guard object["offset"] as? Int == uploads[upload]?.bytes.count else {
                        return [line(["id": id, "ok": false, "error": ["error_code": "attachment_rejected", "message": "bad_offset"]])]
                    }
                    uploads[upload]!.bytes.append(Data(base64Encoded: object["data"] as! String)!)
                    return [ok(["received": uploads[upload]!.bytes.count])]
                default:
                    let upload = uploads.removeValue(forKey: object["upload"] as! String)!
                    stored[upload.hash] = upload.bytes
                    return [ok(["stored": ["hash": upload.hash, "mime_type": "image/png", "byte_count": upload.bytes.count]])]
                }
            case "conversation-attachment-read":
                let bytes = stored[object["hash"] as! String] ?? Data()
                let offset = object["offset"] as? Int ?? 0
                let length = object["length"] as? Int ?? bytes.count
                let piece = bytes.subdata(in: min(offset, bytes.count)..<min(bytes.count, offset + length))
                return [ok(["hash": object["hash"]!, "mime_type": "image/png", "byte_count": bytes.count, "offset": offset,
                            "data": piece.base64EncodedString(), "eof": offset + piece.count >= bytes.count])]
            case "conversation-op":
                let op = object["op"] as! [String: Any]
                ops.append(op)
                switch op["kind"] as! String {
                case "message.send":
                    let parts = op["parts"] as! [[String: Any]]
                    sentParts.append(parts)
                    let text = parts.compactMap { $0["text"] as? String }.joined()
                    let mine = message(author: "user_local", text: text, client: op["client_msg_id"] as! String, parts: parts)
                    messages.append(mine)
                    rev += 1
                    let sent = line(["event": "conversation-changed", "conversation": "conv_chief", "rev": rev, "transaction": NSNull(),
                                     "change": ["kind": "message", "message": mine]])
                    let reply = ok(["rev": rev, "seq": mine["seq"]!, "replayed": false, "change": ["kind": "message", "message": mine]])
                    rev += 1
                    let readCursor = line(["event": "conversation-changed", "conversation": "conv_chief", "rev": rev, "transaction": NSNull(),
                                           "change": ["kind": "read-cursor", "participant": "agent_mux", "seq": mine["seq"]!]])
                    let typing = line(["event": "conversation-typing", "conversation": "conv_chief", "participant": "agent_mux", "on": true])
                    let answer = message(author: "agent_mux", text: "On it.", client: "chief-1")
                    messages.append(answer)
                    rev += 1
                    let answered = line(["event": "conversation-changed", "conversation": "conv_chief", "rev": rev, "transaction": NSNull(),
                                         "change": ["kind": "message", "message": answer]])
                    return [reply, sent, readCursor, typing, answered]
                case "question.answer":
                    lastApproval = object["approval"] as? [String: Any]
                    let messageID = op["message_id"] as! String
                    let part = op["part_index"] as! Int
                    guard let index = messages.firstIndex(where: { $0["id"] as? String == messageID }) else { return [] }
                    var parts = messages[index]["parts"] as! [[String: Any]]
                    parts[part]["state"] = ["kind": "answered", "answer": op["answer"]!]
                    messages[index]["parts"] = parts
                    rev += 1
                    return [ok(["rev": rev, "replayed": false, "change": ["kind": "message-updated", "message": messages[index]]])]
                case "reaction.add":
                    let messageID = op["message_id"] as! String
                    guard let index = messages.firstIndex(where: { $0["id"] as? String == messageID }) else { return [] }
                    var reactions = messages[index]["reactions"] as! [[String: Any]]
                    reactions.append(["author": "user_local", "part_index": 0, "kind": op["reaction"]!, "at": "2026-10-12T09:42:00.000Z"])
                    messages[index]["reactions"] = reactions
                    rev += 1
                    return [ok(["rev": rev, "replayed": false, "change": ["kind": "message-updated", "message": messages[index]]])]
                default:
                    rev += 1
                    return [ok(["rev": rev, "replayed": false, "change": ["kind": "read-cursor", "participant": "user_local", "seq": messages.count]])]
                }
            default:
                return [line(["id": id, "ok": false, "error": "unknown command"])]
            }
        }
    }
}

@Suite struct ChiefDaemonBackendTests {
    @Test func findsSubscribesSendsAndReceivesChief() async throws {
        let daemon = FakeDaemon()
        let link = MockMacLink { _, request in daemon.respond(request) }
        let backend = try await ChiefDaemonBackend.open(link: link)
        var events = backend.events().makeAsyncIterator()

        guard case .connected(let info, let me, let lagged)? = await events.next() else {
            Issue.record("expected connected first")
            return
        }
        #expect(info.id == "conv_chief")
        #expect(info.title == "Chief")
        #expect(me == "user_local")
        #expect(!lagged)
        #expect(daemon.commands.prefix(3) == ["conversation-list", "subscribe", "conversation-snapshot"])
        #expect(!daemon.commands.contains("conversation-create"))

        let sent = try await backend.send(ConversationOutgoingDraft(clientMessageID: "c-1", text: "run the tests", replyToID: nil, attachmentIDs: []))
        #expect(sent.seq == 1)
        #expect(sent.clientMessageID == "c-1")
        // Chief's read cursor follows the reply at once and can be applied first: read then.
        switch sent.delivery {
        case .delivered, .read: break
        default: Issue.record("expected delivered or read, got \(sent.delivery)")
        }

        var sawTyping = false
        var sawRead = false
        var chiefReply: ConversationMessage?
        while chiefReply == nil, let event = await events.next() {
            switch event {
            case .typing(let who, let on): sawTyping = sawTyping || (who == "agent_mux" && on)
            case .message(let message, _):
                if message.senderID == "agent_mux" { chiefReply = message }
                if message.id == sent.id, case .read = message.delivery { sawRead = true }
            default: break
            }
        }
        #expect(sawTyping)
        #expect(sawRead)
        #expect(chiefReply?.text == "On it.")

        let reacted = try await backend.react(messageID: chiefReply!.id, reaction: .heart)
        #expect(reacted.reactions == [ConversationReactionMark(participantID: "user_local", reaction: .heart)])

        let page = try await backend.history(beforeSeq: nil, limit: 50)
        #expect(page.messages.map(\.seq) == [1, 2])
        #expect(!page.hasMore)
        backend.close()
    }
}

/// The first value `work` produces within `limit`, else nil: a wait that
/// can fail but never hangs the run.
func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask { try? await Task.sleep(for: limit); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Waits on the main actor until `condition` holds; past the watchdog, or when the
/// test is cancelled, it records an issue and throws instead of spinning forever.
@MainActor func waitUntil(_ what: String, within watchdog: Duration = waitWatchdog,
                          sourceLocation: SourceLocation = #_sourceLocation,
                          _ condition: @MainActor () -> Bool) async throws {
    guard await eventually(watchdog: watchdog, condition) else {
        Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
        throw CancellationError()
    }
}

/// How long a wait may run before it gives up: a watchdog against a hang, not a
/// time the work is expected to take. It counts only time the wait could run: in
/// the full kit the main thread was held over a minute, every main-actor Chief test
/// ran about 85 s instead of 7, and waits that woke past a wall-clock deadline gave up on
/// their first look, before the work they waited on (held just as long) got its turn.
let waitWatchdog: Duration = .seconds(60)

/// A wall-clock stop for a wait whose main thread stays busy but keeps coming back to
/// it, whatever watchdog the wait asked for: only a backstop. A main thread blocked
/// for good stops the wait too; the suite's time limit ends that.
let waitBackstop: Duration = .seconds(600)

/// Whether `condition` came to hold within `watchdog` of the wait's own running time,
/// before the task was cancelled. It waits on the condition's own state rather than on
/// time: it wakes when observable state the condition read changes (Observation), and
/// checks again every `tick` for state that isn't observable, such as a test double's
/// log of requests. A wake that comes late because the main thread was held counts only
/// the time it asked for, so a hold never uses up the wait.
@MainActor func eventually(watchdog: Duration = waitWatchdog, tick: Duration = .milliseconds(20),
                           _ condition: @MainActor () -> Bool) async -> Bool {
    let backstop = ContinuousClock.now.advanced(by: waitBackstop)
    var left = watchdog
    while true {
        let wake = Wake()
        let met = withObservationTracking { condition() } onChange: {
            Task { @MainActor in wake.fire() }
        }
        if met { return true }
        if Task.isCancelled || left <= .zero || ContinuousClock.now >= backstop { return false }
        // Never past what is left, however long the tick.
        let nap = min(max(tick, .milliseconds(1)), left)
        let start = ContinuousClock.now
        let ticker = Task { @MainActor in
            try? await Task.sleep(for: nap)
            wake.fire()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { wake.wait($0) }
        } onCancel: {
            Task { @MainActor in wake.fire() }
        }
        ticker.cancel()
        left -= min(ContinuousClock.now - start, nap)
    }
}

/// One wake-up of ``eventually``: the first of a change, a tick or a cancel resumes it.
@MainActor private final class Wake {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(_ continuation: CheckedContinuation<Void, Never>) {
        if fired { continuation.resume() } else { self.continuation = continuation }
    }

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite struct ChiefPageReadTests {
    /// A page read (a resync's, or any caller's other than the store's) must
    /// not move the live-event cursor: an event the page's snapshot already
    /// counted still reaches the store. Before, `history` absorbed the
    /// snapshot's `rev`, so a `conversation-changed` that landed after the
    /// reply was dropped as stale and the store never saw the change (the
    /// cause of `tryAgainSendsTheMessageTheFailedTurnAnswered` hanging when
    /// CmuxMobileChiefTests ran in parallel and the reply won the race).
    @Test func aPageReadDoesNotSwallowALaterEvent() async throws {
        let daemon = FakeDaemon()
        let backend = try await ChiefDaemonBackend.open(link: MockMacLink { _, request in daemon.respond(request) })
        let events = backend.events()
        let connected = await within(.seconds(10)) {
            for await event in events { if case .connected = event { return true } }
            return nil
        }
        try #require(connected == true, "expected connected")
        // Chief posts; the Mac's snapshot counts it before its event arrives.
        daemon.queueChiefMessage("Done.", deliverOn: "conversation-typing")
        let page = try await backend.history(beforeSeq: nil, limit: 50)
        #expect(page.messages.map(\.text) == ["Done."])
        // The event lands after the page reply.
        await backend.setTyping(false)
        let delivered = await within(.seconds(10)) {
            for await event in events {
                if case .message(let message, _) = event, message.text == "Done." { return message.id }
            }
            return nil
        }
        #expect(delivered == page.messages.first?.id, "the live event was dropped after a page read")
        backend.close()
    }
}

@Suite struct ChiefLiveRulesTests {
    func preferences() -> ChiefPreferences {
        let suite = "cmuxMobile.chief.tests.\(UUID().uuidString)"
        return ChiefPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    /// The phone never creates Chief: a Mac whose Home has not run yet is an
    /// honest disconnect with the reason, not a new conversation.
    @Test func noChiefOnTheMacIsAnHonestDisconnect() async throws {
        let daemon = FakeDaemon(chiefStarted: false)
        let backend = try await ChiefDaemonBackend.open(link: MockMacLink { _, request in daemon.respond(request) })
        var events = backend.events().makeAsyncIterator()
        guard case .disconnected(let reason)? = await events.next() else {
            Issue.record("expected a disconnect")
            return
        }
        #expect(reason == ChiefDaemonBackend.notStarted)
        #expect(!daemon.commands.contains("conversation-create"))
    }

    /// The conversation the Mac's Home shows: the oldest with agent_mux.
    @Test func picksTheOldestChiefConversation() {
        let wire = ChiefWire(identity: .standard)
        let chief: [[String: Any]] = [["id": "user_local"], ["id": "agent_mux"]]
        let list: [[String: Any]] = [
            ["id": "conv_B", "created_at": "2026-10-12T09:00:00.000Z", "participants": chief],
            ["id": "conv_A", "created_at": "2026-10-12T09:00:00.000Z", "participants": chief],
            ["id": "conv_0", "created_at": "2026-10-11T09:00:00.000Z", "participants": [["id": "user_local"], ["id": "agent_codex"]]],
            ["id": "conv_C", "created_at": "2026-10-13T09:00:00.000Z", "participants": chief],
        ]
        #expect(wire.chiefConversation(in: list) == "conv_A")
    }

    @Test func mentionsTravelAsRuns() throws {
        let wire = ChiefWire(identity: .standard)
        let part = wire.textPart("hi @Chief", mentions: [ConversationMention(participantID: "agent_mux", location: 3, length: 6)])
        let runs = try #require(part["runs"] as? [[String: Any]])
        #expect(runs.first?["mention"] as? String == "agent_mux")
        #expect(runs.first?["start"] as? Int == 3)
        let message = try #require(wire.message(["id": "msg_1", "seq": 1, "author": "agent_mux", "parts": [part], "reactions": []], peerReadSeq: 0))
        #expect(message.mentions == [ConversationMention(participantID: "agent_mux", location: 3, length: 6)])
    }

    /// Hide Alerts and Send Read Receipts are real: kept for the conversation,
    /// and with receipts off reading never moves the Mac's read cursor.
    @Test func receiptsOffKeepsTheReadPositionOnThePhone() async throws {
        let daemon = FakeDaemon()
        let preferences = preferences()
        let channel = try await MockMacLink { _, request in daemon.respond(request) }.openChannel(service: "chief", args: [:])
        let backend = ChiefDaemonBackend(client: DaemonClient(channel: channel), preferences: preferences)
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()
        let info = try await backend.updateListState(ConversationListStateChange(muted: true, sendReadReceipts: false))
        #expect(info.listState.muted)
        #expect(!info.listState.sendReadReceipts)
        #expect(preferences.muted("conv_chief"))
        await backend.markRead(upToSeq: 3)
        #expect(!daemon.ops.contains { $0["kind"] as? String == "read_cursor.set" })
        // QA 2026-10-27: a new backend (the link came back) still knows the
        // position read here; it was in memory only, so unread came back.
        let again = ChiefDaemonBackend(client: DaemonClient(channel: try await MockMacLink { _, request in daemon.respond(request) }
            .openChannel(service: "chief", args: [:])), preferences: preferences)
        var reconnected = again.events().makeAsyncIterator()
        var readAfterReconnect: Int?
        while readAfterReconnect == nil, let event = await reconnected.next() {
            if case .readState(let state) = event { readAfterReconnect = state.lastReadSeq }
        }
        #expect(readAfterReconnect == 3)
        again.close()
        // Back on: the position read here goes to the Mac.
        _ = try await backend.updateListState(ConversationListStateChange(sendReadReceipts: true))
        #expect(daemon.ops.contains { $0["kind"] as? String == "read_cursor.set" && $0["seq"] as? Int == 3 })
    }

    @Test func engineControlRepliesDecode() throws {
        let report = #"{"protocol":"cmux.protocol/2","type":"response","id":"r1","ok":true,"result":{"engine":{"harness":"claude","model":"opus","effort":"high"},"choice":{"model":"opus"},"recent":[{"model":"opus","status":"done","ms":4200,"cost_usd":0.12}],"offered":{"models":[{"id":"opus","name":"Opus"},{"id":"sonnet","name":"Sonnet"}],"efforts":["low","high"]}}}"#
        let got: ChiefEngineReport = try ChiefControl.decode(Data(report.utf8), mutation: false)
        #expect(got.engine.model == "opus")
        #expect(got.offered.models.map(\.id) == ["opus", "sonnet"])
        #expect(got.harnesses == ["claude", "codex"])
        let set = #"{"protocol":"cmux.protocol/2","type":"response","id":"r2","ok":true,"result":{"value":{"engine":{"harness":"codex"}},"generation":"g","revision":"0","replayed":false}}"#
        let after: ChiefEngineReport = try ChiefControl.decode(Data(set.utf8), mutation: true)
        #expect(after.engine.harness == "codex")
        let refused = #"{"protocol":"cmux.protocol/2","type":"response","id":"r3","ok":false,"error":{"code":"operation.failed","message":"x","details":{"reason":"not_configured"},"retryable":false}}"#
        #expect(throws: ChiefControlError.self) { let _: ChiefEngineReport = try ChiefControl.decode(Data(refused.utf8), mutation: false) }
    }
}

/// Audit B9: a message written to Chief before it connects is kept and sent
/// once it does, never dropped.
@Suite @MainActor struct ChiefOutboxTests {
    @Test func waitsOnDiskAndSendsOnConnect() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
        let outbox = ChiefOutbox(file: file)
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: outbox)
        session.send(ConversationComposeMessage(text: "run the tests"))
        #expect(session.outbox.count == 1)
        #expect(outbox.load().map(\.message.text) == ["run the tests"])
        // A relaunch keeps it.
        #expect(ChiefSession(backend: ChiefOfflineBackend(), outbox: outbox).outbox.count == 1)
        session.use(ChiefMockBackend(sleep: { _ in }))
        try await waitUntil("the outbox message to go out") { session.store.messages.contains(where: { $0.text == "run the tests" && $0.seq != nil }) }
        #expect(session.outbox.isEmpty)
        #expect(outbox.load().isEmpty)
    }
}

@Suite struct ChiefMockBackendTests {
    @Test func repliesWithTypingAndTapback() async throws {
        let backend = ChiefMockBackend(sleep: { _ in })
        var events = backend.events().makeAsyncIterator()
        guard case .connected(let info, _, _)? = await events.next() else {
            Issue.record("expected connected")
            return
        }
        #expect(info.title == "Chief")
        let history = try await backend.history(beforeSeq: nil, limit: 5)
        #expect(history.messages.count == 5)
        #expect(history.hasMore)

        let sent = try await backend.send(ConversationOutgoingDraft(clientMessageID: "x", text: "thanks, what's the status?", replyToID: nil, attachmentIDs: []))
        var typing = false
        var tapback: ConversationReaction?
        var reply: ConversationMessage?
        while reply == nil, let event = await events.next() {
            switch event {
            case .typing(_, let on): typing = typing || on
            case .message(let message, _):
                if message.id == sent.id { tapback = message.reactions.first?.reaction ?? tapback }
                if message.senderID == ChiefIdentity.standard.chiefID { reply = message }
            default: break
            }
        }
        #expect(typing)
        #expect(tapback == .heart)
        #expect(reply?.text.contains("workspaces") == true)
        // Idempotent on the client id.
        let again = try await backend.send(ConversationOutgoingDraft(clientMessageID: "x", text: "thanks", replyToID: nil, attachmentIDs: []))
        #expect(again.id == sent.id)
    }
}

/// A 4 x 3 PNG.
private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAE0lEQVR4nGPkqjjBAANMcBY6BwAvkAFQPo8GTQAAAABJRU5ErkJggg==")!

@Suite struct ChiefAttachmentTests {
    /// User feedback: a photo sent to Chief came back "Not Delivered".
    @Test func mockDeliversPhotosAndRepliesToThem() async throws {
        let backend = ChiefMockBackend(sleep: { _ in })
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()
        let uploaded = try await backend.uploadImage(tinyPNG, mimeType: "image/png")
        #expect(uploaded.kind == .image)
        #expect(uploaded.width == 4 && uploaded.height == 3)
        let sent = try await backend.send(ConversationOutgoingDraft(clientMessageID: "p", text: "", replyToID: nil, attachmentIDs: [uploaded.id]))
        #expect(sent.attachments.map(\.id) == [uploaded.id])
        #expect(sent.attachments.first?.localData == tinyPNG)
        #expect(sent.delivery == .delivered)
        var reply: ConversationMessage?
        while reply == nil, let event = await events.next() {
            if case .message(let message, _) = event, message.senderID == ChiefIdentity.standard.chiefID { reply = message }
        }
        #expect(reply?.text.contains("photo") == true)
    }

    @Test func storeSendsAPhotoWithTextToTheMock() async throws {
        let store = await ConversationStore(backend: ChiefMockBackend(sleep: { _ in }))
        await store.start()
        try await waitUntil("the store to connect") { store.meID != nil }
        await store.send(text: "look", images: [(data: tinyPNG, width: 4, height: 3, mimeType: "image/png")])
        try await waitUntil("the photo to be sent") { !store.messages.contains(where: { $0.seq == nil }) }
        let mine = await store.messages.filter { $0.senderID == ChiefIdentity.standard.meID && !$0.attachments.isEmpty }
        #expect(mine.count == 1)
        #expect(mine.first?.delivery?.isFailed == false)
    }

    /// `conversation-attachment-upload` begin, chunk, commit; the send names
    /// the hash in an `attachment` part; a photo from Chief is read by hash.
    @Test func daemonUploadsByHashAndReadsIncomingBytes() async throws {
        let daemon = FakeDaemon()
        let link = MockMacLink { _, request in daemon.respond(request) }
        let backend = try await ChiefDaemonBackend.open(link: link)
        var events = backend.events().makeAsyncIterator()
        _ = await events.next()
        let photo = daemon.seedChiefPhoto(tinyPNG)

        let uploaded = try await backend.uploadImage(tinyPNG, mimeType: "image/png")
        #expect(daemon.commands.filter { $0 == "conversation-attachment-upload" }.count == 3)
        #expect(uploaded.width == 4 && uploaded.height == 3)
        let sent = try await backend.send(ConversationOutgoingDraft(clientMessageID: "a-1", text: "the chart", replyToID: nil, attachmentIDs: [uploaded.id]))
        let parts = try #require(daemon.sentParts.last)
        #expect(parts.map { $0["type"] as? String } == ["attachment", "text"])
        #expect(parts[0]["byte_count"] as? Int == tinyPNG.count)
        #expect(sent.attachments.first?.localData == tinyPNG)
        #expect(sent.text == "the chart")

        let page = try await backend.history(beforeSeq: nil, limit: 50)
        let incoming = try #require(page.messages.first { $0.senderID == "agent_mux" && !$0.attachments.isEmpty })
        #expect(incoming.attachments.first?.id == "att:\(photo)")
        #expect(incoming.attachments.first?.localData == tinyPNG)
        #expect(daemon.commands.contains("conversation-attachment-read"))
        backend.close()
    }
}

#if os(iOS)
import UIKit

@Suite @MainActor struct ChiefDirectoryTests {
    func directory() -> ChiefDirectory {
        let chief = ChiefDirectory.recipients(store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: []), identity: .standard, place: .mac)
        let agent = ChiefRecipient(
            contact: ConversationContact(id: "tab:t1", name: "Claude · cmux", initials: "CL", colorHex: "#636366",
                                         handles: [ConversationContactHandle(value: "cmux", label: "Claude", service: .iMessage)]),
            route: .agent(AgentChatDestination(workspaceID: "ws", tabID: "t1"))
        )
        return ChiefDirectory(recipients: [chief[0], agent])
    }

    @Test func listsChiefFirstAndSearchesNames() async throws {
        let directory = directory()
        #expect(try await directory.searchContacts("", limit: 10, excluding: []).map(\.id) == ["agent_mux", "tab:t1"])
        #expect(try await directory.searchContacts("clau", limit: 10, excluding: []).map(\.id) == ["tab:t1"])
        #expect(try await directory.lookupHandles(["nobody"]).first?.service == nil)
    }

    @Test func oneAgentOpensItsChatSeveralOpenChief() async throws {
        let directory = directory()
        let agent = try await directory.createConversation([.participant("tab:t1")])
        #expect(agent.info.id == "tab:t1")
        let chief = try await directory.createConversation([.participant("agent_mux")])
        #expect(chief.info.id == ChiefDirectory.chiefContactID)
        let both = try await directory.createConversation([.participant("agent_mux"), .participant("tab:t1")])
        #expect(both.info.id == ChiefDirectory.chiefContactID)
        await #expect(throws: ConversationBackendError.self) { try await directory.createConversation([.handle("nobody")]) }
    }
}
/// New Message (or Forward) addressed to one agent sends the whole message as
/// that agent's prompt: its text and every image, bytes and order kept. Images
/// were dropped (an image-only message sent nothing).
@Suite @MainActor struct ChiefComposeAgentRouteTests {
    final class Recorder: AgentSessionSource {
        let summary: AgentSessionSummary
        var sent: [AgentClientIntent] = []
        init(summary: AgentSessionSummary) { self.summary = summary }
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 1])
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1, 2])

    /// Routes `message` to a one-agent conversation; returns the prompts the agent's source got.
    func route(_ message: ConversationComposeMessage) -> [(text: String, attachments: [AgentAttachment])] {
        let suffix = UUID().uuidString
        let tabID = "t-\(suffix)", workspaceID = "ws-\(suffix)", macID = "m-\(suffix)"
        let tab = WorkspaceTab(id: tabID, kind: .agent, title: "Claude", harness: "claude")
        let workspace = Workspace(id: workspaceID, macID: macID, title: "cmux", directory: "~", tabs: [tab], lastActivityAt: Date())
        let store = AppStore(teams: [], activeTeamID: "", workspaces: [workspace], feed: [])
        let agents = AgentSessionDirectory.shared
        let previous = agents.makeSource
        var recorder: Recorder?
        agents.makeSource = { summary in
            let made = Recorder(summary: summary)
            recorder = made
            return made
        }
        defer {
            agents.makeSource = previous
            agents.invalidate(id: tabID, macID: macID)
        }
        let agent = ChiefRecipient(
            contact: ConversationContact(id: "tab:\(tabID)", name: "Claude · cmux", initials: "CL", colorHex: "#636366", handles: []),
            route: .agent(AgentChatDestination(workspaceID: workspaceID, tabID: tabID))
        )
        let directory = ChiefDirectory(recipients: [agent])
        var opened: [HomeConversationRoute] = []
        let composer = ChiefComposer(store: store) { opened.append($0) }
        let creation = ConversationCreation(
            info: ConversationInfo(id: "tab:\(tabID)", title: "Claude · cmux", kind: .direct,
                                   participants: [ConversationParticipant(id: "tab:\(tabID)", name: "Claude · cmux", initials: "CL", colorHex: "#636366", isMe: false)]),
            created: false, service: .iMessage
        )
        composer.route(creation, message: message, directory: directory)
        #expect(opened == [.agent(AgentChatDestination(workspaceID: workspaceID, tabID: tabID))])
        return (recorder?.sent ?? []).compactMap { intent in
            guard case let .prompt(text, attachments, _, _, _) = intent else { return nil }
            return (text, attachments)
        }
    }

    @Test func textAndImagesReachTheAgentInOrder() throws {
        let prompts = route(ConversationComposeMessage(text: "look at these", images: [
            ConversationComposeImage(data: Self.png, width: 1, height: 1, mimeType: "image/png"),
            ConversationComposeImage(data: Self.jpeg, width: 2, height: 2, mimeType: "image/jpeg"),
        ]))
        let prompt = try #require(prompts.first)
        #expect(prompts.count == 1)
        #expect(prompt.text == "look at these")
        #expect(prompt.attachments.map(\.kind) == [.image, .image])
        #expect(prompt.attachments.map(\.data) == [Self.png, Self.jpeg])
        #expect(prompt.attachments.map(\.imageMIMEType) == ["image/png", "image/jpeg"])
        try #require(prompt.attachments.count == 2)
        #expect(prompt.attachments[0].name.hasSuffix(".png"))
        #expect(prompt.attachments[1].name.hasSuffix(".jpg"))
        #expect(Set(prompt.attachments.map(\.id)).count == 2)
    }

    @Test func encodedImageBytesOverrideDeclaredMimeType() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let validPNG = renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let image = ConversationComposeImage(data: validPNG, width: 2, height: 2, mimeType: "image/heic")
        let attachment = try #require(ChiefComposer.attachments([image]).first)
        #expect(attachment.name.hasSuffix(".png"))
        #expect(attachment.imageMIMEType == "image/png")
        #expect(attachment.data == validPNG)
    }

    @Test func imageBytesWinOverTheDeclaredMimeType() throws {
        let image = ConversationComposeImage(data: Self.png, width: 1, height: 1, mimeType: "image/heic")
        let attachment = try #require(ChiefComposer.attachments([image]).first)
        #expect(attachment.kind == .image)
        #expect(attachment.name.hasSuffix(".png"))
        #expect(attachment.imageMIMEType == "image/png")
    }

    @Test func unsupportedDecodedImageIsConvertedToJpeg() throws {
        // A complete 1x1, 24-bit BMP (red pixel, padded four-byte row).
        let bmp = try #require(Data(base64Encoded: "Qk06AAAAAAAAADYAAAAoAAAAAQAAAAEAAAABABgAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAD/AA=="))
        try #require(UIImage(data: bmp) != nil)
        #expect(AgentAttachment(kind: .image, name: "source", data: bmp).imageMIMEType == nil)
        let attachment = try #require(ChiefComposer.attachments([
            ConversationComposeImage(data: bmp, width: 1, height: 1, mimeType: "image/jpeg")
        ]).first)
        #expect(attachment.kind == .image)
        #expect(attachment.name.hasSuffix(".jpg"))
        #expect(attachment.imageMIMEType == "image/jpeg")
        #expect(attachment.data != bmp)
        let jpeg = try #require(attachment.data)
        #expect(UIImage(data: jpeg) != nil)
    }

    @Test func undecodableImageIsSentAsAFile() throws {
        let image = ConversationComposeImage(data: Data([0x01, 0x02, 0x03]), width: 1, height: 1, mimeType: "image/png")
        let attachment = try #require(ChiefComposer.attachments([image]).first)
        #expect(attachment.kind == .file)
        #expect(attachment.imageMIMEType == nil)
    }

    @Test func anImageOnlyMessageStillSends() throws {
        let prompts = route(ConversationComposeMessage(text: "", images: [
            ConversationComposeImage(data: Self.png, width: 1, height: 1, mimeType: "image/png"),
        ]))
        let prompt = try #require(prompts.first)
        #expect(prompts.count == 1)
        #expect(prompt.text == "")
        #expect(prompt.attachments.map(\.data) == [Self.png])
    }

    @Test func aTextOnlyMessageSendsNoAttachments() throws {
        let prompts = route(ConversationComposeMessage(text: "run the tests"))
        let prompt = try #require(prompts.first)
        #expect(prompts.count == 1)
        #expect(prompt.text == "run the tests")
        #expect(prompt.attachments.isEmpty)
    }

    @Test func anEmptyMessageSendsNothing() {
        #expect(route(ConversationComposeMessage(text: "  ")).isEmpty)
    }
}
#endif
