import CmuxHomeCore
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation
import Testing

/// The one path behind the group info sheet, the Home row menu and the `home.*` group actions
/// (palette, CLI, MCP): `HomeGroupActions` over a HomeStore. The mock's "Launch" group is me
/// (Lawrence), Aziz and Leo; "conv_austin" is a DM with Austin.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct HomeGroupActionsTests {
    let launch = ConversationID("conv_launch")
    let dm = ConversationID("conv_austin")
    let me = ParticipantID("user_me")

    /// Records what reaches the mute seam (the sidebar source in the app).
    @MainActor final class FakeMuting: HomeConversationMuting {
        var mutable: Set<ConversationID> = []
        var muted: Set<ConversationID> = []
        var calls: [(Bool, ConversationID)] = []
        func canMute(_ id: ConversationID) -> Bool { mutable.contains(id) }
        func isMuted(_ id: ConversationID) -> Bool { muted.contains(id) }
        func setMuted(_ on: Bool, _ id: ConversationID) {
            calls.append((on, id))
            if on { muted.insert(id) } else { muted.remove(id) }
        }
    }

    func started(muting: FakeMuting = FakeMuting()) async throws -> (HomeStore, HomeGroupActions) {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        try await until { store.isOnline && !store.rows.isEmpty }
        let contacts = [HomeContact(id: ParticipantID("user_austin"), name: "Austin", source: .team)]
        return (store, HomeGroupActions(store: store, muting: muting, contacts: { contacts }))
    }

    func row(_ store: HomeStore, _ id: ConversationID) -> InboxRow? { store.rows.first { $0.id == id } }

    func until(_ seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the condition never held")
                return
            }
            await Task.yield()
        }
    }

    @Test func renameRetitlesTheGroup() async throws {
        let (store, actions) = try await started()
        let outcome = await actions.rename(launch, to: "  Lisbon trip ")
        #expect(outcome == .done)
        try await until { row(store, launch)?.title == "Lisbon trip" }
        #expect(actions.info(launch)?.title == "Lisbon trip")
    }

    @Test func aDirectMessageHasNoNameToChange() async throws {
        let (_, actions) = try await started()
        #expect(await actions.rename(dm, to: "x") == .notAGroup)
    }

    @Test func addingByNameMakesThemMembers() async throws {
        let (store, actions) = try await started()
        let outcome = await actions.add(named: "austin", to: launch)
        #expect(outcome == .done)
        try await until { row(store, launch)?.summary.participants.contains { $0.id == ParticipantID("user_austin") } == true }
        let names = actions.info(launch)?.members.map(\.name) ?? []
        #expect(names.contains("Austin"))
    }

    @Test func addingSomeoneUnknownSaysWho() async throws {
        let (_, actions) = try await started()
        #expect(await actions.add(named: "Nobody Here", to: launch) == .unknownPerson("Nobody Here"))
    }

    @Test func removingAMemberByNameTakesThemOut() async throws {
        let (store, actions) = try await started()
        #expect(await actions.remove(named: "Aziz", from: launch) == .done)
        try await until { row(store, launch)?.summary.participants.count == 2 }
        #expect(actions.info(launch)?.members.contains { $0.name == "Aziz" } == false)
        #expect(await actions.remove(named: "Austin", from: launch) == .notAMember("Austin"))
    }

    @Test func leavingTakesTheGroupOutOfMyList() async throws {
        let (store, actions) = try await started()
        #expect(await actions.leave(launch) == .left)
        try await until { row(store, launch) == nil }
        #expect(row(store, launch) == nil)
        #expect(actions.info(launch) == nil)
    }

    @Test func nobodyLeavesADirectMessage() async throws {
        let (store, actions) = try await started()
        #expect(await actions.leave(dm) == .notAGroup)
        #expect(row(store, dm) != nil)
    }

    @Test func hideAlertsReachesTheMuteSeam() async throws {
        let muting = FakeMuting()
        muting.mutable = [launch]
        let (_, actions) = try await started(muting: muting)
        #expect(actions.setMuted(true, launch) == .done)
        #expect(muting.calls.count == 1)
        #expect(muting.calls.first?.0 == true)
        #expect(muting.calls.first?.1 == launch)
        #expect(actions.info(launch)?.muted == true)
        #expect(actions.info(launch)?.canMute == true)
        #expect(actions.setMuted(false, launch) == .done)
        #expect(muting.calls.last?.0 == false)
    }

    @Test func aRowWithoutMuteIsRefusedAndNothingIsSent() async throws {
        let muting = FakeMuting()
        let (_, actions) = try await started(muting: muting)
        #expect(actions.setMuted(true, dm) == .cannotMute)
        #expect(muting.calls.isEmpty)
    }

    @Test func sendPostsTheText() async throws {
        let (store, actions) = try await started()
        #expect(await actions.send("  hello group  ", to: launch) == .done)
        await store.open(launch)
        try await until { store.transcript(for: launch).contains { $0.parts == [.text("hello group")] } }
        #expect(await actions.send("   ", to: launch) == .emptyText)
    }

    @Test func anUnknownConversationIsSaidSo() async throws {
        let (_, actions) = try await started()
        let gone = ConversationID("conv_gone")
        #expect(await actions.rename(gone, to: "x") == .unknownConversation)
        #expect(await actions.leave(gone) == .unknownConversation)
    }

    /// The group info for a DM shows the person; for a group, every member and whether it can be renamed.
    @Test func infoListsMembers() async throws {
        let (_, actions) = try await started()
        let group = try #require(actions.info(launch))
        #expect(group.isGroup)
        #expect(Set(group.members.map(\.name)) == ["Lawrence", "Aziz", "Leo"])
        #expect(group.members.first { $0.isMe }?.id == me)
        let direct = try #require(actions.info(dm))
        #expect(!direct.isGroup)
        #expect(direct.members.filter { !$0.isMe }.map(\.name) == ["Austin"])
    }

    /// `cmux home add-members --people "Austin, leo@x.com ,user_leo"`: one name per comma, trimmed, no empties.
    @Test(arguments: [
        ("Austin, leo@example.com ,user_leo", ["Austin", "leo@example.com", "user_leo"]),
        (" , Aziz,,", ["Aziz"]),
        ("", []),
    ])
    func peopleArgumentSplitsOnCommas(_ text: String, _ names: [String]) {
        #expect(HomeGroupActions.names(in: text) == names)
    }

    /// A person names a member by id, display name (any case) or, for a contact, the same.
    @Test func membersResolveByIdOrName() async throws {
        let (_, actions) = try await started()
        #expect(actions.member("user_leo", in: launch) == ParticipantID("user_leo"))
        #expect(actions.member("LEO", in: launch) == ParticipantID("user_leo"))
        #expect(actions.member("Austin", in: launch) == nil)
        #expect(actions.contact("austin") == ParticipantID("user_austin"))
    }

    /// The owner's refusals as the sheet and the CLI say them.
    @Test func refusalsMapToOutcomes() {
        // Removing someone else: only the group's owner may (the Cloud owner says `forbidden`).
        #expect(HomeGroupOutcome(rejection: .invalid("forbidden"), naming: "Aziz", removing: true) == .ownerOnly)
        #expect(HomeGroupOutcome(rejection: .notAuthorized, naming: "Aziz", removing: true) == .ownerOnly)
        #expect(HomeGroupOutcome(rejection: .notAuthorized, naming: "Aziz") == .forbidden)
        #expect(HomeGroupOutcome(rejection: .invalid("not_reachable"), naming: "Sam") == .notReachable("Sam"))
        #expect(HomeGroupOutcome(rejection: .invalid("kind_forbids"), naming: "") == .notAGroup)
        #expect(HomeGroupOutcome(rejection: .ownerUnreachable, naming: "") == .offline)
        #expect(HomeGroupOutcome(rejection: .invalid("too_many_participants"), naming: "") == .tooMany)
        #expect(HomeGroupOutcome.ownerOnly.message?.isEmpty == false)
        #expect(HomeGroupOutcome.done.message == nil)
    }
}
