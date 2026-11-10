import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextHome
import CmuxNextHomeModel
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Observation
import Testing

/// Review round 6 of cmux#37736, New Message and its sheets on the React Messages page: a first send
/// that is refused or never answered no longer vanishes (F2), HomeStore's own Not Delivered sends
/// reach the page's outbox, the Invite sheet lists the pending invites (G2), Group Info of an unknown
/// conversation is refused (G3), and Group Info and Requests follow what they show (G1, G5).
@MainActor @Suite(.serialized)
struct HomeMessagesR6NewMessageTests {
    /// F2: the owner refuses the first send: nothing is left in HomeStore's log (where the page
    /// never looks), and the answer is the refusal, so New Message keeps its people and its text.
    @Test func aRefusedFirstSendIsTheRefusalAndLeavesNothingBehind() async throws {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try Self.directory())
        store.start()
        defer { store.stop() }
        await Self.until { store.isOnline && !store.rows.isEmpty }
        let id = try #require(store.rows.first?.id)
        let key = IdempotencyKey("first-send-refused")
        await source.failNextSubmits(of: key, times: 1, with: .invalid("message.too_long"))
        var named: String?
        let send = HomeMessagesFirstSend(store: store, contacts: [Self.ada], start: { _, _ in .opened(id) },
                                         refusal: { _, naming in named = naming; return .refused("Too long") })
        let answer = await send.run(Self.fields(text: "hello"), key: key)
        #expect(answer == HomeComposeOutcome.refused("Too long").pageOutcome, "not `opened`: the page keeps New Message")
        #expect(named == "Ada")
        #expect(store.cachedSend(key) == nil, "the refused send left HomeStore's log")
        #expect(store.transcript(for: id).allSatisfy { $0.key != key })
    }

    /// F2: a first send with no answer (here: offline) opens the conversation with the send as the
    /// page keeps one (Not Delivered, Retry under its key), and it leaves HomeStore's queue, so it
    /// never goes from both.
    @Test func anUnansweredFirstSendComesToThePageWithItsKey() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: try Self.directory())
        let id = HomeChiefRosterTests.ada
        let key = IdempotencyKey("first-send-offline")
        let send = HomeMessagesFirstSend(store: store, contacts: [Self.ada], start: { _, _ in .opened(id) },
                                         refusal: { _, _ in .refused("unexpected") })
        let answer = await send.run(Self.fields(text: " hello "), key: key)
        #expect(answer.value(at: ["outcome", "kind"]) == .string("opened"))
        #expect(answer.value(at: ["outcome", "conversation"]) == .string(id.rawValue))
        let row = try #require(answer.value(at: ["outcome", "pending"])?.arrayValue?.first)
        #expect(row.value(at: ["key"]) == .string(key.rawValue))
        #expect(row.value(at: ["conversation"]) == .string(id.rawValue))
        #expect(row.value(at: ["text"]) == .string("hello"))
        #expect(row.value(at: ["failed"]) == .bool(true))
        #expect(store.cachedSend(key) == nil, "HomeStore no longer holds it for its reconnect")
    }

    /// Round 11 F1: the unanswered first send is in the host's outbox before it leaves HomeStore's
    /// queue, so the page losing the answer or reloading before it puts the row loses nothing: a
    /// new page's `outbox.load` shows it, under its key.
    @Test func anUnansweredFirstSendIsKeptBeforeItLeavesTheQueue() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: try Self.directory())
        let id = HomeChiefRosterTests.ada
        let key = IdempotencyKey("first-send-offline-kept")
        let send = HomeMessagesFirstSend(store: store, contacts: [Self.ada], start: { _, _ in .opened(id) },
                                         refusal: { _, _ in .refused("unexpected") })
        // The page never sees this answer (it reloaded while the send was out).
        _ = await send.run(Self.fields(text: "hello"), key: key)
        #expect(store.cachedSend(key) == nil, "it left the native queue")
        let rows = try #require(HomeMessagesOutbox(store: store).load().value(at: ["pending", id.rawValue])?.arrayValue)
        #expect(rows.map { $0.value(at: ["key"]) } == [.string(key.rawValue)], "the host's outbox kept it first")
        #expect(rows.first?.value(at: ["text"]) == .string("hello"))
    }

    /// F2: HomeStore's own Not Delivered sends (the native composer's, a send a host made) move into
    /// the page's outbox when the page loads it, under their keys, and stay there.
    @Test func theOutboxTakesHomeStoresNotDeliveredSends() async throws {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try Self.directory())
        store.start()
        defer { store.stop() }
        await Self.until { store.isOnline && !store.rows.isEmpty }
        let id = try #require(store.rows.first?.id)
        let key = IdempotencyKey("native-failed")
        await source.failNextSubmits(of: key, times: 1, with: .invalid("refused"))
        _ = try? await store.perform(.sendMessage(conversation: id, parts: [.text("from before")]), key: key)
        #expect(store.cachedSend(key) != nil, "the fixture leaves a Not Delivered send in the log")
        let outbox = HomeMessagesOutbox(store: store)
        let rows = try #require(outbox.load().value(at: ["pending", id.rawValue])?.arrayValue)
        #expect(rows.count == 1)
        #expect(rows.first?.value(at: ["key"]) == .string(key.rawValue))
        #expect(rows.first?.value(at: ["text"]) == .string("from before"))
        #expect(store.cachedSend(key) == nil, "it left the log: it shows and goes from the page only")
        #expect(outbox.load().value(at: ["pending", id.rawValue])?.arrayValue?.count == 1, "kept for the next launch")
    }

    /// Round 7 F1: a Not Delivered send the outbox refuses (past ``HomeMessagesOutbox/maxEntryBytes``)
    /// stays in HomeStore's log: it leaves the log only once the outbox keeps it, so it is never lost.
    @Test func aSendTheOutboxRefusesStaysInHomeStoresLog() async throws {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source, blobCacheDirectory: try Self.directory())
        store.start()
        defer { store.stop() }
        await Self.until { store.isOnline && !store.rows.isEmpty }
        let id = try #require(store.rows.first?.id)
        let key = IdempotencyKey("native-failed-oversized")
        await source.failNextSubmits(of: key, times: 1, with: .invalid("refused"))
        let text = String(repeating: "x", count: HomeMessagesOutbox.maxEntryBytes + 1)
        _ = try? await store.perform(.sendMessage(conversation: id, parts: [.text(text)]), key: key)
        #expect(store.cachedSend(key) != nil, "the fixture leaves a Not Delivered send in the log")
        let outbox = HomeMessagesOutbox(store: store)
        #expect(outbox.load().value(at: ["pending", id.rawValue]) == nil, "the outbox refuses it")
        #expect(store.cachedSend(key) != nil, "so it stays in the log, not lost")
    }

    /// G2: `contacts` lists the invites still pending, as the native Invite sheet's `pending`.
    @Test func contactsListThePendingInvites() {
        let invited = Participant(id: ParticipantID("addr_1"), kind: .human, displayName: "", membership: .invited, invitedContact: "a@b.co")
        let rows = [HomeChiefRosterTests.row(HomeChiefRosterTests.ada, title: "", participants: [invited], at: 1)]
        let answer = HomeContact.pageAnswer([Self.ada], inviteTeam: "Manaflow", rows: rows)
        #expect(answer.value(at: ["pendingInvites"]) == .array([.string("a@b.co")]))
        #expect(answer.value(at: ["inviteTeam"]) == .string("Manaflow"))
        #expect(answer.value(at: ["contacts"])?.arrayValue?.count == 1)
    }

    /// G6: a Chief in New Message's To: list carries the native look: where it runs as the list
    /// tags it ("Main · Cloud"), with a non-default engine, and when it was last active; a person
    /// carries none.
    @Test func aChiefContactCarriesItsToListLook() {
        let rows = [HomeChiefRosterTests.chief(HomeChiefRosterTests.hosted, "chief_hosted", "Chief", at: 5), HomeChiefRosterTests.dm(HomeChiefRosterTests.ada, at: 1)]
        let roster = HomeChiefRoster(main: HomeChiefRosterTests.hosted, places: [HomeChiefRosterTests.hosted: .cloud])
        let chief = HomeContact(id: ParticipantID("chief_hosted"), name: "Chief", source: .agent)
        let answer = HomeContact.pageAnswer([chief, Self.ada], inviteTeam: nil, rows: rows, roster: roster,
                                            harnesses: ["chief_hosted": "codex"], now: Date(timeIntervalSince1970: 10_000))
        let entries = answer.value(at: ["contacts"])?.arrayValue ?? []
        let tag = roster.tag(for: HomeChiefRosterTests.hosted, engine: ChiefBackend.badge(for: "codex"))
        #expect(tag != nil)
        #expect(entries.first?.value(at: ["look", "tag"]) == tag.map(JSONValue.string))
        #expect(entries.first?.value(at: ["look", "activity"])?.stringValue?.isEmpty == false)
        #expect(entries.last?.value(at: ["look"]) == nil, "a person has no look")
    }

    /// G3: Group Info the page did not present (a conversation it does not list) is refused as an
    /// unknown conversation, as the native presentGroupInfo refused it; other answers say nothing.
    @Test func groupInfoOfAnUnknownConversationIsRefused() {
        let unknown = HomeGroupOutcome.unknownConversation.message ?? ""
        #expect(HomeGroupOutcome.presentRefusal(sheet: "groupInfo", answer: .object(["presented": .bool(false)])) == unknown)
        #expect(HomeGroupOutcome.presentRefusal(sheet: "groupInfo", answer: .object(["presented": .bool(true)])) == nil)
        #expect(HomeGroupOutcome.presentRefusal(sheet: "requests", answer: .object(["presented": .bool(false)])) == nil)
        #expect(HomeGroupOutcome.presentRefusal(sheet: "groupInfo", answer: nil) == nil, "a page that never answered is not a refusal")
    }

    /// G3: `home.conversationInfo` for a conversation Home does not know is refused at once (the
    /// CLI and the palette get the reason), before any page is asked.
    @Test func conversationInfoRefusesAnUnknownConversation() {
        let services = HomeChiefDefaultTests.services()
        HomeMessagesPageRulesTests.kept.append(services)
        // The app binds its handlers at launch (AppActions.bind); bare AppServices has none, and an
        // unbound action refuses nothing a test can read.
        AppActions.bind(services)
        let reason = services.registry.capturingRefusal {
            _ = services.registry.perform("home.conversationInfo",
                                          invocation: ActionInvocation(arguments: ["conversation": .string("conv_nowhere")], origin: .user))
        }
        #expect(reason == HomeGroupOutcome.unknownConversation.message)
    }

    /// G1 and G5: a follow stream sends what it reads now and after each change, then `gone` once
    /// its subject is gone, and stops.
    @Test func aFollowSendsEachChangeThenGone() async {
        let model = Followed()
        var events: [JSONValue] = []
        let subscription = HomeMessagesFollow.start({ model.title.map { .string($0) } }, onEvent: { events.append($0) })
        defer { subscription.cancel() }
        await Self.until { events.count == 1 }
        model.title = "Renamed"
        await Self.until { events.count == 2 }
        model.title = nil
        await Self.until { events.count == 3 }
        #expect(events == [.string("Lisbon"), .string("Renamed"), HomeMessagesFollow.gone])
        model.title = "Back"
        for _ in 0..<50 { await Task.yield() }
        #expect(events.count == 3, "the stream ended with gone")
    }

    @Observable @MainActor final class Followed {
        var title: String? = "Lisbon"
    }

    static let ada = HomeContact(id: ParticipantID("ada"), name: "Ada", source: .team)

    static func fields(text: String) -> [String: JSONValue] {
        ["recipients": .array([.object(["contact": .string("ada")])]), "text": .string(text)]
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "home-messages-r6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Yields until `done` holds (at most a few seconds of yields).
    static func until(_ done: () -> Bool) async {
        for _ in 0..<20_000 where !done() { await Task.yield() }
    }
}
