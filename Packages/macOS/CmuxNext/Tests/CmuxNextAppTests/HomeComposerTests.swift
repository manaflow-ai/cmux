@testable import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHome
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// New Message, Invite and New Chief as Home ops (home-messaging.md 4.1,
/// 4.2, 16.10): one person is `dm.open` with their id, several people are a
/// group, an address is a DM invite; the owner's refusals come back as what
/// the sheet says (not reachable offers an invite, rate limited waits).
@MainActor
@Suite struct HomeComposerTests {
    static let austin = HomeContact(id: ParticipantID("user_austin"), name: "Austin", source: .team)
    static let aziz = HomeContact(id: ParticipantID("user_aziz"), name: "Aziz", source: .team)

    final class Recorder {
        var ops: [HomeOp] = []
        var answer: (HomeOp) throws -> HomeOpResult = { _ in HomeOpResult(rev: 1, conversation: ConversationID("conv_new")) }
        var composer: HomeComposer {
            HomeComposer { [self] op in
                ops.append(op)
                return try answer(op)
            }
        }
    }

    @Test func onePersonOpensTheirDMByID() async {
        let recorder = Recorder()
        let outcome = await recorder.composer.start([.contact(Self.austin)], title: "")
        #expect(recorder.ops == [.openDirect(peer: ParticipantID("user_austin"))])
        #expect(outcome == .opened(ConversationID("conv_new")))
    }

    @Test func severalPeopleMakeAGroupWithItsName() async {
        let recorder = Recorder()
        let outcome = await recorder.composer.start([.contact(Self.austin), .contact(Self.aziz)], title: "Launch")
        #expect(recorder.ops == [.createGroup(title: "Launch", participants: [ParticipantID("user_austin"), ParticipantID("user_aziz")])])
        #expect(outcome == .opened(ConversationID("conv_new")))
    }

    @Test func anAddressStartsADMInviteAndPeopleWithAddressesAreRefusedLocally() async {
        let recorder = Recorder()
        _ = await recorder.composer.start([.address(.email("lee@example.com"))], title: "")
        #expect(recorder.ops == [.startConversation(contacts: [.email("lee@example.com")], firstMessage: [])])
        let mixed = await recorder.composer.start([.contact(Self.austin), .address(.email("lee@example.com"))], title: "")
        #expect(mixed == .mixedRecipients)
        #expect(recorder.ops.count == 1, "nothing goes to the owner")
    }

    @Test func refusalsBecomeOutcomes() async {
        let recorder = Recorder()
        recorder.answer = { _ in throw HomeRejection.invalid("not_reachable") }
        #expect(await recorder.composer.start([.contact(Self.austin)], title: "") == .notReachable("Austin"))
        recorder.answer = { _ in throw HomeRejection.invalid("home.rate_limited") }
        #expect(await recorder.composer.start([.contact(Self.austin)], title: "") == .rateLimited)
        recorder.answer = { _ in throw HomeRejection.ownerUnreachable }
        #expect(await recorder.composer.start([.contact(Self.austin)], title: "") == .offline)
        recorder.answer = { _ in throw HomeRejection.invalid("invite.rate_limited") }
        #expect(await recorder.composer.invite(.email("lee@example.com")) == .refused(HomeConversationStrings.inviteRefusal("invite.rate_limited")))
    }

    @Test func anInviteIsADMInviteToTheAddress() async {
        let recorder = Recorder()
        let outcome = await recorder.composer.invite(.email("lee@example.com"))
        #expect(recorder.ops == [.invite(contact: .email("lee@example.com"))])
        #expect(outcome == .invited(ConversationID("conv_new")))
        #expect(await recorder.composer.invite(.phone("+15555550100")) == .invalidAddress("+15555550100"))
    }

    /// An archived Chief's conversation leaves the list; other rows stay.
    @Test func archivedChiefsAreHiddenFromThePage() {
        let me = ParticipantID("user_local")
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func row(_ id: String, _ other: Participant) -> InboxRow {
            let summary = ConversationSummary(id: ConversationID(id), participants: [Participant(id: me, kind: .human, displayName: "Me"), other],
                                              createdAt: at, updatedAt: at)
            return InboxRow(summary: summary, kind: summary.kind(me: me), title: other.displayName, preview: "", previewAttachments: nil,
                            previewAuthor: nil, timestamp: at, unread: 0, isPinned: false, isSending: false, hasFailedSend: false,
                            isTyping: false)
        }
        let rows = [row("conv_a", Participant(id: ParticipantID("agent_old"), kind: .agent, displayName: "Old", agentClass: .chief)),
                    row("conv_b", Participant(id: ParticipantID("agent_new"), kind: .agent, displayName: "New", agentClass: .chief)),
                    row("conv_c", Participant(id: ParticipantID("user_austin"), kind: .human, displayName: "Austin"))]
        #expect(TopHomePageView.visible(rows, archivedChiefs: ["agent_old"], me: me).map(\.id.rawValue) == ["conv_b", "conv_c"])
    }
}

/// The team and the Chiefs behind New Message and New Chief, read from and
/// written to the API Worker as the signed-in user.
@MainActor
@Suite struct HomeDirectoryTests {
    final class Calls {
        var bodies: [(String, [String: Any])] = []
        var replies: [String: [String: Any]] = [:]
        var call: HomeDirectory.Call {
            { [self] path, body in
                bodies.append((path, body))
                return replies[body["op"] as? String ?? ""] ?? [:]
            }
        }
    }

    @Test func theTeamListsEveryMemberButMeByName() async {
        let calls = Calls()
        calls.replies["team.members.list"] = ["value": ["members": [
            ["user": "user_stack-me", "role": "owner", "display_name": "Lawrence"],
            ["user": "user_zed", "role": "member", "display_name": "Aziz"],
            ["user": "user_aus", "role": "member", "display_name": "Austin"],
        ]]]
        let directory = HomeDirectory(call: calls.call, me: { "stack-me" })
        await directory.refresh()
        #expect(directory.teamMembers.map(\.name) == ["Austin", "Aziz"])
        #expect(directory.teamMembers.map(\.id.rawValue) == ["user_aus", "user_zed"])
        #expect(calls.bodies.first?.0 == "v1/read")
    }

    @Test func newChiefAndArchiveChiefAreUserOpsWithKeysAndTheRevision() async throws {
        let calls = Calls()
        calls.replies["chief.create"] = ["value": ["id": "agent_r", "display_name": "Research", "is_default": false, "rev": 1,
                                                   "main_conversation": "conv_r", "archived_at": NSNull()]]
        calls.replies["chief.archive"] = ["value": ["id": "agent_r", "rev": 2]]
        let directory = HomeDirectory(call: calls.call, me: { nil })
        let record = try await directory.createChief(named: "Research")
        #expect(record.mainConversation == "conv_r")
        let create = try #require(calls.bodies.last)
        #expect(create.0 == "v1/ops")
        #expect((create.1["params"] as? [String: Any])?["display_name"] as? String == "Research")
        #expect(create.1["origin"] as? String == "user")
        #expect((create.1["idempotency_key"] as? String)?.isEmpty == false)
        try await directory.archiveChief("agent_r")
        let archive = try #require(calls.bodies.last)
        #expect((archive.1["params"] as? [String: Any])?["expected_rev"] as? Int == 1)
        #expect(directory.archivedChiefs == ["agent_r"])
        #expect(directory.chiefs.isEmpty)
    }

    @Test func aWorkerRefusalThrowsItsCode() async {
        let calls = Calls()
        calls.replies["chief.create"] = ["_tag": "PolicyRefused", "code": "policy.denied", "message": "no chiefs"]
        let directory = HomeDirectory(call: calls.call, me: { nil })
        await #expect(throws: FeedServiceError.self) { try await directory.createChief(named: "X") }
    }
}

/// `dm.open` with a person the user reaches: the peer is their participant
/// id (the account's own id goes out as its cloud id), and the opened DM
/// shows at once.
nonisolated extension CloudHomeSourceTests {
    @Test func openingADirectMessageSendsTheParticipantAsThePeer() async throws {
        let opened = "conv_dm_01J0000000000000000000000D"
        let (source, daemon, tape) = await configured(.init(op: { _ in
            CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0,
                                                           participants: [F.participant("user_stack-me", "Me"), F.participant("user_aus", "Austin")]))
        }))
        let result = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_dm"), op: .openDirect(peer: ParticipantID("user_aus"))))
        #expect(result.conversation == ConversationID(opened))
        #expect(daemon.opRequests.last?.op == .dmOpen(peer: .participant("user_aus")))
        #expect(daemon.opRequests.last?.conversation == nil)
        #expect(await tape.wait { summaries($0, opened).contains { $0.kind(me: F.localMe) == .direct } })
    }

    @Test func aNewGroupNamesDirectoryPeopleByName() async throws {
        let group = "conv_01J0000000000000000000000E"
        let (source, daemon, _) = await configured(.init(op: { _ in
            CloudConversationOpResult(conversation: F.head(group, rev: 1, lastSeq: 0, kind: "group"))
        }))
        source.remember([Participant(id: ParticipantID("user_aus"), kind: .human, displayName: "Austin")])
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_g2"),
                                               op: .createGroup(title: "", participants: [ParticipantID("user_aus")])))
        #expect(daemon.opRequests.last?.op == .create(title: nil, participants: [F.participant("user_stack-me", "Me"),
                                                                                 F.participant("user_aus", "Austin")]))
    }
}
