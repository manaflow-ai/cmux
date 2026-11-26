import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// Home group chats are managed from the Mac (plans/cmux-next/home-dm-group-chats/AUDIT.md
/// items 3-6 and 9): rename, add people, remove someone, leave, and my own typing reaches the
/// owner. The seed's "Launch" group is me, Aziz and Leo; "conv_austin" is a DM.
@MainActor
@Suite struct GroupManagementTests {
    let launch = ConversationID("conv_launch")
    let dm = ConversationID("conv_austin")
    let me = ParticipantID("user_me")

    func started() async -> HomeStore {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        return store
    }

    func row(_ store: HomeStore, _ id: ConversationID) -> InboxRow? { store.rows.first { $0.id == id } }

    @Test func renamingAGroupRetitlesItsRow() async throws {
        let store = await started()
        try await store.perform(.renameConversation(conversation: launch, title: "Lisbon trip"))
        await waitUntil { row(store, launch)?.title == "Lisbon trip" }
        #expect(row(store, launch)?.title == "Lisbon trip")
    }

    @Test func aDirectMessageHasNoNameToChange() async {
        let store = await started()
        await #expect(throws: HomeRejection.invalid("kind_forbids")) {
            try await store.perform(.renameConversation(conversation: dm, title: "x"))
        }
    }

    @Test func addingPeopleMakesThemMembers() async throws {
        let store = await started()
        try await store.perform(.addParticipants(conversation: launch, participants: [ParticipantID("user_austin")]))
        await waitUntil { row(store, launch)?.summary.participants.contains { $0.id == ParticipantID("user_austin") } == true }
        let ids = Set(row(store, launch)?.summary.participants.map(\.id) ?? [])
        #expect(ids == [me, ParticipantID("user_aziz"), ParticipantID("user_leo"), ParticipantID("user_austin")])
    }

    /// A group of three that loses one person is still a group (the owner says so), not a DM.
    @Test func aGroupStaysAGroupWhenSomeoneIsRemoved() async throws {
        let store = await started()
        #expect(row(store, launch)?.kind == .group)
        try await store.perform(.removeParticipant(conversation: launch, participant: ParticipantID("user_aziz")))
        await waitUntil { row(store, launch)?.summary.participants.count == 2 }
        #expect(row(store, launch)?.kind == .group)
        #expect(row(store, launch)?.title == "Launch")
    }

    @Test func leavingAGroupTakesItOutOfMyList() async throws {
        let store = await started()
        try await store.perform(.removeParticipant(conversation: launch, participant: me))
        await waitUntil { row(store, launch) == nil }
        #expect(row(store, launch) == nil)
    }

    @Test func nobodyLeavesADirectMessage() async {
        let store = await started()
        await #expect(throws: HomeRejection.invalid("kind_forbids")) {
            try await store.perform(.removeParticipant(conversation: dm, participant: me))
        }
    }

    /// My typing goes to the owner while the field has text, and stops when it is empty again.
    @Test func composingSendsMyTypingAndEmptyingEndsIt() async {
        let store = await started()
        await store.open(dm)
        store.composing("h", in: dm)
        await waitUntil { store.typing[dm]?.contains(me) == true }
        #expect(store.typing[dm]?.contains(me) == true)
        store.composing("", in: dm)
        await waitUntil { store.typing[dm] == nil }
        #expect(store.typing[dm] == nil)
    }
}
