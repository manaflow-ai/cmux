import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// Group chats with Chiefs (plans/cmux-next/chief-group-chats-DESIGN.md): who answers a message
/// follows the owner's wake rule (home-core `wakesFor`), and the group's "Chiefs Reply" setting
/// (`wake_policy`) changes it. The seed's Chiefs are "Chief" (agent_chief), "Release Chief"
/// (agent_release) and "Infra Chief"; Aziz is a person.
@MainActor
@Suite struct ChiefGroupChatTests {
    let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Lawrence")
    let aziz = Participant(id: ParticipantID("user_aziz"), kind: .human, displayName: "Aziz")
    let chief = Participant(id: ParticipantID("agent_chief"), kind: .agent, displayName: "Chief", agentClass: .chief)
    let release = Participant(id: ParticipantID("agent_release"), kind: .agent, displayName: "Release Chief", agentClass: .chief)

    // MARK: The rule

    @Test func automaticAnswersEveryMessageWithOnePersonAndOneChief() {
        let who = ChiefReplyPolicy.auto.responders(among: [me, chief], author: me.id)
        #expect(who == [chief.id])
    }

    @Test func automaticAnswersOnlyAMentionWithSeveralChiefs() {
        let people = [me, chief, release]
        #expect(ChiefReplyPolicy.auto.responders(among: people, author: me.id).isEmpty)
        #expect(ChiefReplyPolicy.auto.responders(among: people, author: me.id, mentioned: [release.id]) == [release.id])
    }

    @Test func automaticAnswersOnlyAMentionWithSeveralPeople() {
        #expect(ChiefReplyPolicy.auto.responders(among: [me, aziz, chief], author: me.id).isEmpty)
    }

    @Test func aReplyToAChiefWakesThatChief() {
        let who = ChiefReplyPolicy.auto.responders(among: [me, aziz, chief, release], author: aziz.id, repliedTo: release.id)
        #expect(who == [release.id])
    }

    @Test func mentionsOnlyIgnoresTheOneToOneRule() {
        #expect(ChiefReplyPolicy.mentions.responders(among: [me, chief], author: me.id).isEmpty)
    }

    @Test func everyMessageWakesEveryChiefButNotOnAChiefsOwnMessage() {
        let people = [me, aziz, chief, release]
        #expect(ChiefReplyPolicy.all.responders(among: people, author: aziz.id) == [chief.id, release.id])
        // A Chief's message never wakes Chiefs by the policy (no loops); a mention still does.
        #expect(ChiefReplyPolicy.all.responders(among: people, author: chief.id).isEmpty)
        #expect(ChiefReplyPolicy.all.responders(among: people, author: chief.id, mentioned: [release.id]) == [release.id])
    }

    @Test func theWireNamesAreTheOwners() {
        #expect(ChiefReplyPolicy(rawValue: "auto") == .auto)
        #expect(ChiefReplyPolicy(rawValue: "mentions") == .mentions)
        #expect(ChiefReplyPolicy(rawValue: "all") == .all)
        #expect(ChiefReplyPolicy.default == .auto)
    }

    // MARK: A Chief's conversation shared with teammates (cmux#25569)

    @Test func mySharedChiefStaysMyChiefAndNamesSenders() {
        let mine = Participant(id: chief.id, kind: .agent, displayName: "Chief", agentClass: .chief, ownerUser: me.id)
        let alone = ConversationSummary(id: ConversationID("conv_chief"), participants: [me, mine],
                                        createdAt: .distantPast, updatedAt: .distantPast, declaredKind: .chief)
        #expect(alone.kind(me: me.id) == .chief)
        #expect(!alone.showsSenderNames(me: me.id))
        let shared = ConversationSummary(id: ConversationID("conv_chief"), participants: [me, aziz, mine],
                                         createdAt: .distantPast, updatedAt: .distantPast, declaredKind: .chief)
        #expect(shared.kind(me: me.id) == .chief)
        #expect(shared.showsSenderNames(me: me.id))
        // The teammate it was shared with sees someone else's Chief in a group, never as their own Chief.
        #expect(shared.kind(me: aziz.id) == .group)
        #expect(shared.showsSenderNames(me: aziz.id))
        // Only the owner shares it (Add People… in its info).
        #expect(shared.isMyChiefLine(me: me.id))
        #expect(!shared.isMyChiefLine(me: aziz.id))
    }

    // MARK: Through the store

    func started() async -> HomeStore {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        return store
    }

    func summary(_ store: HomeStore, _ id: ConversationID) -> ConversationSummary? { store.rows.first { $0.id == id }?.summary }

    /// A group of me, Chief and Release Chief, made as New Message makes it.
    func chiefsGroup(_ store: HomeStore) async throws -> ConversationID {
        let result = try await store.perform(.createGroup(title: "Ship it", participants: [chief.id, release.id]))
        let id = try #require(result.conversation)
        await waitUntil { summary(store, id) != nil }
        return id
    }

    @Test func aGroupWithTwoChiefsHasBothAndStartsAutomatic() async throws {
        let store = await started()
        let id = try await chiefsGroup(store)
        let ids = Set(summary(store, id)?.participants.map(\.id) ?? [])
        #expect(ids == [me.id, chief.id, release.id])
        #expect(summary(store, id)?.chiefReplies ?? .default == .auto)
    }

    @Test func settingChiefsReplyChangesTheGroup() async throws {
        let store = await started()
        let id = try await chiefsGroup(store)
        try await store.perform(.setChiefReplies(conversation: id, policy: .all))
        await waitUntil { summary(store, id)?.chiefReplies == .all }
        #expect(summary(store, id)?.chiefReplies == .all)
    }

    @Test func aDirectMessageHasNoChiefsReplySetting() async {
        let store = await started()
        await #expect(throws: HomeRejection.invalid("kind_forbids")) {
            try await store.perform(.setChiefReplies(conversation: ConversationID("conv_austin"), policy: .all))
        }
    }

    @Test func onEveryMessageBothChiefsAnswer() async throws {
        let store = await started()
        let id = try await chiefsGroup(store)
        try await store.perform(.setChiefReplies(conversation: id, policy: .all))
        let before = summary(store, id)?.lastSeq ?? 0
        try await store.perform(.sendMessage(conversation: id, parts: [.text("status?")]))
        await waitUntil { (summary(store, id)?.lastSeq ?? 0) >= before + 3 }
        #expect(summary(store, id)?.lastSeq == before + 3)
    }

    @Test func automaticallyOnlyTheMentionedChiefAnswers() async throws {
        let store = await started()
        let id = try await chiefsGroup(store)
        let before = summary(store, id)?.lastSeq ?? 0
        let text = "@Release Chief cut the build"
        let mention = Mention(start: 0, length: 14, participant: release.id)
        try await store.perform(.sendMessage(conversation: id, parts: [.text(text, mentions: [mention])]))
        await waitUntil { summary(store, id)?.lastMessage?.author == release.id }
        #expect(summary(store, id)?.lastMessage?.author == release.id)
        #expect(summary(store, id)?.lastSeq == before + 2)
    }
}
