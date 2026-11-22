import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The first page of a chat whose view opened empty (a chat picked in Home's list) installs in one
/// rebuild, at the newest message, and does not arrive as animated receives that slide the rows up
/// (the user, 2026-11-03: "every time i switch imessage chief chats, i see it scroll all the way to the
/// bottom"), and neither do the messages that arrive while that page is read. A message that arrives in
/// a chat already shown is still a receive, and so is my own send
/// in an empty chat (it flies in from the message box).
@MainActor @Suite struct HomeFirstPageDiffTests {
    static let me = ParticipantID("user_me")

    static func items(_ count: Int, from start: Int = 0) -> [TranscriptItem] {
        (start..<start + count).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(UInt64(i + 1)), author: HomeDiffCostTests.chief,
                           parts: [.text("message \(i)")], createdAt: HomeDiffCostTests.base.addingTimeInterval(Double(i)),
                           delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
    }

    @Test(arguments: [1, 2, 3])
    func aFirstPageOfAFewMessagesIsOneRebuild(_ count: Int) {
        let diff = HomeDiff.plan(old: [], new: Self.items(count), oldSummary: nil,
                                 newSummary: HomeDiffCostTests.summary(lastSeq: count), aliases: [:], me: Self.me)
        #expect(diff.rebuild, "the first page arrived as \(diff.actions.count) receives")
    }

    /// Messages that arrive while the first page is read reach the view one by one: each is still part
    /// of opening the chat, not a new message to animate in.
    @Test func aMessageThatArrivesWhileTheChatOpensIsARebuild() {
        let old = Self.items(1), new = Self.items(2)
        let diff = HomeDiff.plan(old: old, new: new, oldSummary: HomeDiffCostTests.summary(lastSeq: 1),
                                 newSummary: HomeDiffCostTests.summary(lastSeq: 2), aliases: [:], me: Self.me, opening: true)
        #expect(diff.rebuild, "the second message of an opening chat arrived as \(diff.actions.count) receives")
    }

    @Test func aNewMessageInAShownChatIsStillAReceive() {
        let old = Self.items(5), new = Self.items(6)
        let diff = HomeDiff.plan(old: old, new: new, oldSummary: HomeDiffCostTests.summary(lastSeq: 5),
                                 newSummary: HomeDiffCostTests.summary(lastSeq: 6), aliases: [:], me: Self.me)
        #expect(!diff.rebuild)
        #expect(diff.actions.contains { if case .receive = $0 { return true } else { return false } })
    }

    @Test func mySendInAnEmptyChatIsNotARebuild() {
        let mine = Self.items(1)
        let diff = HomeDiff.plan(old: [], new: mine, oldSummary: nil, newSummary: HomeDiffCostTests.summary(lastSeq: 1),
                                 aliases: [mine[0].key: "local_1"], me: Self.me)
        #expect(!diff.rebuild, "my own send must fly in, not reload the chat")
    }
}
