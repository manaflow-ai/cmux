import AppKit
import CmuxHomeCore
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
@testable import CmuxNextHomeEngine
import Testing

/// Message requests on the Mac (plans/cmux-next/home-messaging-invites/DESIGN.md 2.3, 2.5): a
/// stranger's invite waits under Message Requests with Accept, Decline and Block (drawn by the
/// React Messages page); the sender's
/// row says who it waits for; no internal id is ever shown.
@MainActor
struct HomeMessageRequestsTests {
    static let austin = HomeMessageRequest(conversation: ConversationID("conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS"), inviter: "Lawrence Chen",
                                           isGroup: false, title: nil, preview: "hi", createdAt: nil, trusted: false)
    static let lunch = HomeMessageRequest(conversation: ConversationID("conv_0Y05MEWEFMQQB63VDHQB9MXAJT"), inviter: "Frank",
                                          isGroup: true, title: "Lunch", preview: "", createdAt: nil, trusted: true)

    @Test func refreshListsTheOwnersRequests() async {
        let source = FakeRequestSource(listed: [Self.austin, Self.lunch])
        let requests = HomeMessageRequests(source: source)
        await requests.reload()
        #expect(requests.items == [Self.austin, Self.lunch])
    }

    @Test(arguments: [HomeRequestAnswer.accept, .decline, .block])
    func anAnswerTakesTheRequestOffTheList(_ answer: HomeRequestAnswer) async {
        let source = FakeRequestSource(listed: [Self.austin, Self.lunch])
        let requests = HomeMessageRequests(source: source)
        await requests.reload()
        source.listed = [Self.lunch]
        let done = await requests.answer(Self.austin.conversation, answer)
        #expect(done)
        #expect(requests.items == [Self.lunch])
        #expect(source.answers == [Self.austin.conversation: answer])
    }

    @Test func aRefusedAnswerPutsTheRequestBack() async {
        let source = FakeRequestSource(listed: [Self.austin], refuse: true)
        let requests = HomeMessageRequests(source: source)
        await requests.reload()
        let done = await requests.answer(Self.austin.conversation, .accept)
        #expect(!done)
        #expect(requests.items == [Self.austin])
    }

    @Test func theSenderSeesWhoTheInviteWaitsForNeverAnID() {
        let me = Participant(id: ParticipantID("user_local"), kind: .human, displayName: "Lawrence")
        let masked = Participant(id: ParticipantID("addr_ABREQ2MXXDJ3CH86MMYYKA0FPC"), kind: .human, displayName: "",
                                 membership: .invited, invitedContact: "a***@manaflow.ai")
        let named = ConversationSummary(id: ConversationID("conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS"), participants: [me, masked],
                                        createdAt: .distantPast, updatedAt: .distantPast)
        #expect(named.homeInviteWaiting(me: me.id) == HomeConversationStrings.waitingFor("a***@manaflow.ai"))
        let bare = Participant(id: ParticipantID("addr_ABREQ2MXXDJ3CH86MMYYKA0FPC"), kind: .human,
                               displayName: "addr_ABREQ2MXXDJ3CH86MMYYKA0FPC", membership: .invited)
        let unnamed = ConversationSummary(id: named.id, participants: [me, bare], createdAt: .distantPast, updatedAt: .distantPast)
        let shown = unnamed.homeInviteWaiting(me: me.id)
        #expect(shown == HomeConversationStrings.invitedLabel)
        #expect(shown?.contains("addr_") == false)
        let joined = ConversationSummary(id: named.id, participants: [me, Participant(id: ParticipantID("user_austin"), kind: .human, displayName: "Austin")],
                                         createdAt: .distantPast, updatedAt: .distantPast)
        #expect(joined.homeInviteWaiting(me: me.id) == nil)
    }
}

/// The owner's requests as a test sets them; records each answer.
@MainActor
final class FakeRequestSource: HomeMessageRequestSource {
    var listed: [HomeMessageRequest]
    var answers: [ConversationID: HomeRequestAnswer] = [:]
    let refuse: Bool

    init(listed: [HomeMessageRequest], refuse: Bool = false) {
        self.listed = listed
        self.refuse = refuse
    }

    func messageRequests() async throws -> [HomeMessageRequest] { listed }

    func answer(_ conversation: ConversationID, _ answer: HomeRequestAnswer) async throws {
        if refuse { throw CancellationError() }
        answers[conversation] = answer
    }
}
