import CmuxHomeCore
@testable import CmuxNextHome
import CmuxNextHomeEngine
import Foundation
import Testing

/// Group chats with Chiefs from the Mac (plans/cmux-next/chief-group-chats-DESIGN.md): the
/// Chiefs listed under New Message's To:, `cmux chat create --members` and `cmux chat replies`
/// (one path, `HomeGroupActions`), and the group info's Chiefs Reply row. The mock's Chiefs are
/// "Chief", "Release Chief" and "Infra Chief"; "Launch" is me, Aziz and Leo.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct ChiefGroupChatActionsTests {
    let launch = ConversationID("conv_launch")
    let me = ParticipantID("user_me")
    let chief = ParticipantID("agent_chief")
    let release = ParticipantID("agent_release")

    @MainActor final class NoMuting: HomeConversationMuting {
        func canMute(_ id: ConversationID) -> Bool { false }
        func isMuted(_ id: ConversationID) -> Bool { false }
        func setMuted(_ on: Bool, _ id: ConversationID) {}
    }

    /// The store and the actions, with the app's contacts: team people and every Chief of the list.
    func started() async throws -> (HomeStore, HomeGroupActions) {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        try await until { store.isOnline && !store.rows.isEmpty }
        let austin = HomeContact(id: ParticipantID("user_austin"), name: "Austin", source: .team)
        let me = me
        let actions = HomeGroupActions(store: store, muting: NoMuting(), contacts: {
            [austin] + HomeContact.agents(in: store.rows, me: me)
        })
        return (store, actions)
    }

    func summary(_ store: HomeStore, _ id: ConversationID) -> ConversationSummary? { store.rows.first { $0.id == id }?.summary }

    func until(_ seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the condition never held")
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: cmux chat create

    @Test func createMakesAGroupOfTheNamedChiefsAndPeople() async throws {
        let (store, actions) = try await started()
        let made = await actions.create(named: "Chief, release chief, Austin", title: "Ship it")
        guard case .created(let id) = made else { Issue.record("not created: \(made)"); return }
        try await until { summary(store, id) != nil }
        let ids = Set(summary(store, id)?.participants.map(\.id) ?? [])
        #expect(ids == [me, chief, release, ParticipantID("user_austin")])
        #expect(summary(store, id)?.title == "Ship it")
    }

    @Test func createWithRepliesSetsThePolicyToo() async throws {
        let (store, actions) = try await started()
        let made = await actions.create(named: "Chief, Release Chief", title: "", replies: .all)
        guard case .created(let id) = made else { Issue.record("not created: \(made)"); return }
        try await until { summary(store, id)?.chiefReplies == .all }
        #expect(actions.info(id)?.chiefReplies == .all)
    }

    @Test func createRefusesSomeoneUnknownBeforeSendingAnything() async throws {
        let (store, actions) = try await started()
        let count = store.rows.count
        #expect(await actions.create(named: "Chief, Nobody Here", title: "") == .refused(.unknownPerson("Nobody Here")))
        #expect(await actions.create(named: " , ", title: "") == .refused(.noPeople))
        #expect(store.rows.count == count)
    }

    // MARK: cmux chat replies and group info

    @Test func repliesChangesTheGroupsPolicy() async throws {
        let (store, actions) = try await started()
        guard case .created(let id) = await actions.create(named: "Chief, Release Chief", title: "") else {
            Issue.record("not created"); return
        }
        try await until { summary(store, id) != nil }
        #expect(actions.info(id)?.chiefReplies == .auto)
        #expect(await actions.setChiefReplies(.mentions, id) == .done)
        try await until { actions.info(id)?.chiefReplies == .mentions }
        #expect(actions.info(id)?.chiefReplies == .mentions)
    }

    @Test func aGroupWithoutChiefsShowsNoChiefsReplyRow() async throws {
        let (_, actions) = try await started()
        #expect(actions.info(launch)?.chiefReplies == nil)
    }

    @Test func addingAChiefToAnExistingGroupShowsTheRow() async throws {
        let (store, actions) = try await started()
        #expect(actions.addable(to: launch).contains { $0.id == chief })
        #expect(await actions.add(named: "Chief", to: launch) == .done)
        try await until { summary(store, launch)?.participants.contains { $0.id == chief } == true }
        #expect(actions.info(launch)?.chiefReplies == .auto)
    }

    @Test(arguments: [("auto", ChiefReplyPolicy.auto), ("Mentions", .mentions), (" all ", .all), ("every", nil), ("", nil)])
    func theRepliesArgumentParses(_ text: String, _ policy: ChiefReplyPolicy?) {
        #expect(ChiefReplyPolicy(argument: text) == policy)
    }

    // MARK: New Message's Chiefs (listed under To: before anything is typed)

    @Test func newMessageOffersEachChiefNotChosenYet() {
        let ada = HomeContact(id: ParticipantID("ada"), name: "Ada", source: .team)
        let chief = HomeContact(id: self.chief, name: "Chief", source: .agent)
        let unii = HomeContact(id: ParticipantID("agent_unii"), name: "Unii", source: .agent)
        var draft = HomeNewMessageDraft()
        #expect(draft.chiefShortcuts(contacts: [ada, chief, unii]) == [chief, unii])
        draft.add(.contact(chief))
        #expect(draft.chiefShortcuts(contacts: [ada, chief, unii]) == [unii])
        draft.add(.contact(unii))
        #expect(draft.chiefShortcuts(contacts: [ada, chief, unii]).isEmpty)
    }

    @Test func newMessageListsAtMostSixChiefs() {
        let many = (0..<9).map { HomeContact(id: ParticipantID("agent_\($0)"), name: "Chief \($0)", source: .agent) }
        #expect(HomeNewMessageDraft().chiefShortcuts(contacts: many).count == 6)
    }

    /// Picking two Chiefs in New Message makes a group (not a DM), as the first send does.
    @Test func twoChiefsMakeAGroup() {
        var draft = HomeNewMessageDraft()
        draft.add(.contact(HomeContact(id: chief, name: "Chief", source: .agent)))
        #expect(!draft.isGroup)
        draft.add(.contact(HomeContact(id: release, name: "Release Chief", source: .agent)))
        #expect(draft.isGroup)
    }
}
