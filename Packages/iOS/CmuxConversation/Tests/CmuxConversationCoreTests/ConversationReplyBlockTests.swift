import Foundation
import Testing
@testable import CmuxConversationCore

/// Inline replies in thread blocks, as Messages lays them out (iOS 27.0
/// simulator Messages with its thread links restored, verify/imsg-replies).
@Suite struct ConversationReplyBlockTests {
    private func message(_ seq: Int, _ sender: String, minute: Double, replyTo: String? = nil) -> ConversationMessage {
        ConversationMessage(
            id: "m\(seq)", seq: seq, clientMessageID: nil, senderID: sender,
            sentAt: Date(timeIntervalSince1970: minute * 60), text: "x", replyToID: replyTo, delivery: sender == "me" ? .read(nil) : nil
        )
    }

    private func plan(_ messages: [ConversationMessage]) -> ConversationRunPlan {
        ConversationRunPlan(messages: messages, meID: "me", threadBlocks: true)
    }

    /// "Booking for seven", then my reply to it right under it: no quote and
    /// no line, but the reply still starts its own run (the bubble above keeps
    /// its tail; the gap is the run gap, not the reply block's).
    @Test func aReplyRightUnderItsMessageIsAPlainBubble() {
        let entries = plan([message(1, "me", minute: 0), message(2, "me", minute: 1, replyTo: "m1")]).entries
        #expect(entries[1].replyThread == nil)
        #expect(entries[0].isLastInRun)
        #expect(entries[1].isFirstInRun)
    }

    /// "Let me know by five" quoted once over my two replies in a row: one
    /// quote, the first reply loses its tail, and the line runs on past it.
    @Test func repliesOfOneThreadInARowShareTheFirstOnesQuote() {
        let entries = plan([
            message(1, "a", minute: 0), message(2, "me", minute: 1),
            message(3, "me", minute: 2, replyTo: "m1"), message(4, "me", minute: 3, replyTo: "m1"),
        ]).entries
        #expect(entries[2].replyThread == .init(showsQuote: true, arrival: nil, continuesBelow: true))
        #expect(entries[3].replyThread == .init(showsQuote: false, arrival: .line, continuesBelow: false))
        #expect(!entries[2].isLastInRun, "the block's replies run together")
        #expect(!entries[3].isFirstInRun)
    }

    /// My reply, their reply, my reply, all in one thread: the line passes
    /// beside mine, stops above theirs and starts again under it.
    @Test func aLeadingReplyInTheBlockRestartsTheLineUnderIt() {
        let entries = plan([
            message(1, "a", minute: 0), message(2, "me", minute: 1),
            message(3, "me", minute: 2, replyTo: "m1"), message(4, "a", minute: 3, replyTo: "m1"),
            message(5, "me", minute: 4, replyTo: "m1"), message(6, "me", minute: 5),
        ]).entries
        #expect(entries[3].replyThread == .init(showsQuote: false, arrival: .line, continuesBelow: true))
        #expect(entries[4].replyThread == .init(showsQuote: false, arrival: .belowLeading, continuesBelow: false))
        #expect(entries[5].replyThread == nil)
        #expect(entries[4].isLastInRun, "a plain message under the block starts a run")
    }

    /// A reply to another thread, or one past a plain message, starts a new block.
    @Test func anotherThreadOrAMessageBetweenStartsANewBlock() {
        let entries = plan([
            message(1, "a", minute: 0), message(2, "a", minute: 1), message(3, "me", minute: 2),
            message(4, "me", minute: 3, replyTo: "m1"), message(5, "me", minute: 4, replyTo: "m2"),
            message(6, "me", minute: 5), message(7, "me", minute: 6, replyTo: "m2"),
        ]).entries
        #expect(entries[3].replyThread?.showsQuote == true)
        #expect(entries[3].replyThread?.continuesBelow == false)
        #expect(entries[4].replyThread?.showsQuote == true)
        #expect(entries[6].replyThread?.showsQuote == true)
        #expect(entries[3].isLastInRun && entries[4].isFirstInRun, "different threads do not run together")
    }

    /// A reply to the reply right above it joins that reply's block
    /// ("Reply to a reply" under "Patio for sure").
    @Test func aReplyToTheReplyAboveJoinsItsBlock() {
        let entries = plan([
            message(1, "a", minute: 0), message(2, "me", minute: 1),
            message(3, "me", minute: 2, replyTo: "m1"), message(4, "me", minute: 3, replyTo: "m3"),
        ]).entries
        #expect(entries[3].replyThread?.arrival == .line)
        #expect(entries[2].replyThread?.continuesBelow == true)
    }

    /// Replies chained under the message they answer stay plain bubbles.
    @Test func repliesUnderAnAdjacentReplyStayPlain() {
        let entries = plan([
            message(1, "me", minute: 0), message(2, "me", minute: 1, replyTo: "m1"), message(3, "me", minute: 2, replyTo: "m1"),
        ]).entries
        #expect(entries[1].replyThread == nil)
        #expect(entries[2].replyThread == nil)
    }

    /// A timestamp section between two replies of one thread starts a new block.
    @Test func aTimestampBetweenRepliesStartsANewBlock() {
        let entries = plan([
            message(1, "a", minute: 0), message(2, "me", minute: 1),
            message(3, "me", minute: 2, replyTo: "m1"), message(4, "me", minute: 200, replyTo: "m1"),
        ]).entries
        #expect(entries[2].replyThread?.continuesBelow == false)
        #expect(entries[3].replyThread?.showsQuote == true)
    }

    /// Live changes and older pages plan only part of the transcript; each
    /// part must give the entries (blocks included) the whole plan gives.
    @Test func aPlanForAnyRangeGivesTheWholePlansBlocks() {
        var messages: [ConversationMessage] = []
        for i in 0..<30 {
            let sender = [0, 3, 4, 7, 8, 12, 13, 20].contains(i) ? "a" : "me"
            let replyTo: String? = switch i {
            case 5, 6, 9, 10, 11: "m1"
            case 14: "m14"
            case 15, 16: "m14"
            case 21, 22, 23: "m21"
            case 25: "m24"
            case 27: "m1"
            case 28: "m28"
            case 29: "m1"
            default: nil
            }
            messages.append(message(i + 1, sender, minute: Double(i) + (i == 18 ? 120 : 0), replyTo: replyTo))
        }
        let whole = plan(messages)
        #expect(whole.entries.contains { $0.replyThread?.arrival == .belowLeading } || whole.entries.contains { $0.replyThread?.arrival == .line })
        for start in 0...messages.count {
            for end in [start, min(start + 1, messages.count), messages.count] {
                let part = ConversationRunPlan(messages: messages, meID: "me", range: start..<end, threadBlocks: true)
                #expect(part.entries == Array(whole.entries[start..<end]), "\(start)..<\(end)")
            }
        }
    }

    /// Without thread blocks (the Mac transcript) every reply is a run of its
    /// own and carries no block, as before.
    @Test func withoutThreadBlocksRepliesKeepTheirOwnRuns() {
        let messages = [message(1, "a", minute: 0), message(2, "me", minute: 1), message(3, "me", minute: 2, replyTo: "m1"), message(4, "me", minute: 3, replyTo: "m1")]
        let entries = ConversationRunPlan(messages: messages, meID: "me").entries
        #expect(entries.allSatisfy { $0.replyThread == nil })
        #expect(entries[2].isLastInRun && entries[3].isFirstInRun)
    }

    /// "Table for four" answers "Sounds good", itself a reply to "Let me know
    /// by five": Messages quotes the root, "Let me know by five".
    @Test func aReplyToAReplyQuotesTheThreadsRoot() {
        let messages = [
            message(1, "kate", minute: 0),
            message(2, "me", minute: 1, replyTo: "m1"),
            message(3, "me", minute: 2, replyTo: "m2"),
        ]
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        #expect(ConversationRunPlan.threadRoot(of: "m2") { byID[$0] }?.id == "m1")
        #expect(ConversationRunPlan.threadRoot(of: "m1") { byID[$0] }?.id == "m1")
        // A root that is not loaded leaves no root (no quote, no line), even
        // under a reply to a reply.
        #expect(ConversationRunPlan.threadRoot(of: "m3") { $0 == "m1" ? nil : byID[$0] } == nil)
        #expect(ConversationRunPlan.threadRoot(of: "gone") { byID[$0] } == nil)
    }

    /// A reply to a reply, then a reply to the root: Messages keeps them in
    /// the root's one thread, so the last joins the block (it quoted the
    /// root again before), and my reply to my reply runs with it.
    @Test func aReplyToAnyMessageOfTheBlockJoinsIt() {
        let entries = plan([
            message(1, "a", minute: 0), message(2, "a", minute: 1),
            message(3, "me", minute: 2, replyTo: "m1"), message(4, "me", minute: 3, replyTo: "m3"),
            message(5, "me", minute: 4, replyTo: "m1"),
        ]).entries
        #expect(entries[2].replyThread == .init(showsQuote: true, arrival: nil, continuesBelow: true))
        #expect(entries[3].replyThread == .init(showsQuote: false, arrival: .line, continuesBelow: true))
        #expect(entries[4].replyThread == .init(showsQuote: false, arrival: .line, continuesBelow: false))
        #expect(!entries[2].isLastInRun && !entries[3].isFirstInRun, "a reply to my reply above runs with it")
    }

    /// My reply, my reply to it, then my reply to the root: one block, and
    /// all three run together (4 pt; only the last keeps its tail).
    @Test func mySameThreadRepliesRunTogetherWhateverTheyAnswer() {
        let entries = plan([
            message(1, "a", minute: 0), message(2, "a", minute: 1),
            message(3, "me", minute: 2, replyTo: "m1"), message(4, "me", minute: 3, replyTo: "m3"),
            message(5, "me", minute: 4, replyTo: "m1"),
        ]).entries
        #expect(!entries[3].isLastInRun && !entries[4].isFirstInRun)
        #expect(entries[4].isLastInRun)
    }
}
