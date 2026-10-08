import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

@MainActor
@Suite struct HomeStoreTests {
    func started(_ options: MockHomeSource.Options = .immediate) async -> (HomeStore, MockHomeSource) {
        let source = MockHomeSource(options: options)
        let store = HomeStore(source: source)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        return (store, source)
    }

    @Test func chiefIsPinnedFirst() async {
        let (store, _) = await started()
        #expect(store.rows.first?.title == "Chief")
        #expect(store.rows.first?.kind == .chief)
        #expect(store.rows.first?.isPinned == true)
    }

    @Test func sendIsVisibleAtOnceAndSettlesOnEcho() async throws {
        let (store, _) = await started()
        let id = ConversationID("conv_austin")
        await store.open(id)
        let before = store.transcript(for: id).count
        let key = IdempotencyKey("send-1")
        let result = try await store.perform(.sendMessage(conversation: id, parts: [.text("hello")]), key: key)
        await waitUntil { store.transcript(for: id).last?.delivery == .committed }
        let items = store.transcript(for: id)
        #expect(items.count == before + 1)
        #expect(items.last?.id == key)
        #expect(items.last?.delivery == .committed)
        #expect(result.replayed == false)
        #expect(store.rows.first(where: { $0.id == id })?.preview == "hello")
    }

    @Test func offlineRefusesNewOpsAndQueuesNothing() async {
        let (store, source) = await started()
        await source.setOnline(false)
        await waitUntil { !store.isOnline }
        await #expect(throws: HomeRejection.ownerUnreachable) {
            try await store.perform(.sendMessage(conversation: ConversationID("conv_austin"), parts: [.text("x")]))
        }
        #expect(store.log.isEmpty)
    }

    @Test func replayedKeyIsAppliedOnce() async throws {
        let (store, source) = await started()
        let id = ConversationID("conv_aziz")
        await store.open(id)
        let intent = HomeIntent(key: IdempotencyKey("dup"), op: .sendMessage(conversation: id, parts: [.text("once")]))
        _ = try await source.submit(intent)
        let replay = try await source.submit(intent)
        #expect(replay.replayed)
        let page = try await source.snapshot(of: id, tail: 50)
        #expect(page.messages.filter { $0.clientMessageID == IdempotencyKey("dup") }.count == 1)
    }

    @Test func compose_toNewEmailInvitesAndOpensConversation() async throws {
        let (store, _) = await started()
        let contact = ContactAddress.email("new@example.com")
        #expect(try await store.resolve(contact) == .invitable(contact))
        let result = try await store.perform(.startConversation(contacts: [contact], firstMessage: [.text("join me")]))
        #expect(result.invite?.alreadyMember == false)
        #expect(result.invite?.channel == .email)
        let id = try #require(result.conversation)
        await waitUntil { store.rows.contains { $0.id == id } }
        #expect(store.summary(id)?.hasInvitedParticipant == true)
    }

    @Test func searchCoversHomeMessagesOnly() async throws {
        let (store, _) = await started()
        let hits = try await store.search("phone numbers")
        #expect(hits.map(\.conversation) == [ConversationID("conv_austin")])
    }

    @Test func pagingReachesTheStartOfALongHistory() async {
        let (store, _) = await started(MockHomeSource.Options(chiefHistory: 500, latency: .zero, replyDelay: .zero))
        let id = ConversationID("conv_chief")
        await store.open(id)
        #expect(store.transcript(for: id).count == HomeStore.tailSize)
        while store.hasOlderMessages(in: id) { await store.loadOlder(id) }
        let seqs = store.transcript(for: id).compactMap(\.seq)
        #expect(seqs == Array(1...500))
    }
}

@MainActor
@Suite struct HomeCoreGapTests {
    @Test func typingIsSentButNeverLogged() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        await waitUntil { store.isOnline }
        try await store.perform(.setTyping(conversation: ConversationID("conv_aziz"), on: true))
        #expect(store.log.isEmpty)
    }

    @Test func transcriptItemsCarryReplyThreadAndEdit() {
        let conv = ConversationID("c")
        let edited = Date(timeIntervalSince1970: 5)
        let message = Message(id: MessageID("m2"), conversation: conv, seq: 2, clientMessageID: IdempotencyKey("k2"),
                              author: ParticipantID("u"), parts: [.location(LocationRef(latitude: 1, longitude: 2, label: "Office"))],
                              createdAt: Date(timeIntervalSince1970: 1), editedAt: edited,
                              replyTo: PartRef(message: MessageID("m1")), threadRoot: MessageID("m1"))
        let item = TranscriptWindow(messages: [message]).items(pending: [], me: ParticipantID("me"))[0]
        #expect(item.editedAt == edited)
        #expect(item.replyTo == PartRef(message: MessageID("m1")))
        #expect(item.threadRoot == MessageID("m1"))
        #expect(item.plainText == "Office")
    }

    @Test func demoDataIsPublicAndPinsTheChief() {
        let demo = HomeDemoData(now: Date(timeIntervalSince1970: 1_000_000))
        #expect(demo.conversations.contains { $0.pinRank == 0 && $0.participants.contains(demo.chief) })
    }
}
