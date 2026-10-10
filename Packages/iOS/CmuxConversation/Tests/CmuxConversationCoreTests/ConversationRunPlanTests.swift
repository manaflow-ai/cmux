import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationRunPlanTests {
    private func message(_ seq: Int?, _ sender: String, minute: Double, delivery: ConversationDelivery? = nil, replyTo: String? = nil) -> ConversationMessage {
        ConversationMessage(
            id: seq.map { "m\($0)" } ?? "local:\(minute)", seq: seq, clientMessageID: nil, senderID: sender,
            sentAt: Date(timeIntervalSince1970: minute * 60), text: "x", replyToID: replyTo, delivery: delivery
        )
    }

    @Test func consecutiveSameSenderFormsOneRunWithTailOnLast() {
        let plan = ConversationRunPlan(messages: [
            message(1, "a", minute: 0), message(2, "a", minute: 1), message(3, "a", minute: 2), message(4, "me", minute: 3),
        ], meID: "me")
        #expect(plan.entries.map(\.isFirstInRun) == [true, false, false, true])
        #expect(plan.entries.map(\.isLastInRun) == [false, false, true, true])
    }

    @Test func senderChangeAndTimeBreakSplitRuns() {
        let plan = ConversationRunPlan(messages: [
            message(1, "a", minute: 0), message(2, "a", minute: 10), message(3, "a", minute: 200),
        ], meID: "me")
        // 10 minutes apart breaks the run; 190 minutes also starts a timestamp section.
        #expect(plan.entries.map(\.isFirstInRun) == [true, true, true])
        #expect(plan.entries.map(\.showsTimestamp) == [true, false, true])
    }

    @Test func aReplyStartsItsOwnRun() {
        let plan = ConversationRunPlan(messages: [
            message(1, "a", minute: 0), message(2, "a", minute: 1, replyTo: "m1"),
        ], meID: "me")
        #expect(plan.entries[0].isLastInRun)
        #expect(plan.entries[1].isFirstInRun)
    }

    @Test func aTapbackMakesItsMessageARunOfItsOwn() {
        // Messages (iOS 26.5 and 27.0): a heart on the middle of three sent
        // messages puts tails on all three and 10 pt between runs.
        var reacted = message(2, "me", minute: 1)
        reacted.reactions = [ConversationReactionMark(participantID: "me", reaction: .heart)]
        let plan = ConversationRunPlan(messages: [message(1, "me", minute: 0), reacted, message(3, "me", minute: 2)], meID: "me")
        #expect(plan.entries.map(\.isFirstInRun) == [true, true, true])
        #expect(plan.entries.map(\.isLastInRun) == [true, true, true])
    }

    @Test func typingFromTheSameSenderKeepsTheRunOpen() {
        let plan = ConversationRunPlan(messages: [message(1, "a", minute: 0)], meID: "me", typingParticipantIDs: ["a"])
        #expect(!plan.entries[0].isLastInRun)
    }

    @Test func onlyTheNewestAcknowledgedOutgoingMessageCarriesStatus() {
        let plan = ConversationRunPlan(messages: [
            message(1, "me", minute: 0, delivery: .read(nil)),
            message(2, "me", minute: 1, delivery: .delivered),
            message(nil, "me", minute: 2, delivery: .sending),
        ], meID: "me")
        #expect(plan.entries.map(\.status) == [.none, .delivered, .none])
    }

    @Test func failedSendsAlwaysShowNotDelivered() {
        let plan = ConversationRunPlan(messages: [
            message(1, "me", minute: 0, delivery: .delivered),
            message(nil, "me", minute: 1, delivery: .failed("x")),
        ], meID: "me")
        #expect(plan.entries.map(\.status) == [.delivered, .notDelivered])
    }
}

extension ConversationRunPlanTests {
    @Test func statusStaysOnTheDeliveredMessageWhileANewerOneIsInFlight() {
        let plan = ConversationRunPlan(messages: [
            ConversationMessage(id: "m1", seq: 1, clientMessageID: nil, senderID: "me", sentAt: Date(timeIntervalSince1970: 0), text: "a", delivery: .delivered),
            ConversationMessage(id: "m2", seq: 2, clientMessageID: nil, senderID: "me", sentAt: Date(timeIntervalSince1970: 60), text: "b", delivery: .sent),
        ], meID: "me")
        #expect(plan.entries.map(\.status) == [.delivered, .none])
    }
}

extension ConversationRunPlanTests {
    @Test func statusHidesOnceSomeoneRepliesBelowIt() {
        let plan = ConversationRunPlan(messages: [
            ConversationMessage(id: "m1", seq: 1, clientMessageID: nil, senderID: "me", sentAt: Date(timeIntervalSince1970: 0), text: "a", delivery: .read(nil)),
            ConversationMessage(id: "m2", seq: 2, clientMessageID: nil, senderID: "a", sentAt: Date(timeIntervalSince1970: 60), text: "b"),
        ], meID: "me")
        #expect(plan.entries.map(\.status) == [.none, .none])
    }
}

extension ConversationRunPlanTests {
    /// iOS 26 Messages: "Delivered" stays under the older message while the
    /// newer one is in flight, then moves once the newer one is delivered.
    @Test func statusMovesToTheNewerMessageOnceItIsDelivered() {
        let inFlight = ConversationRunPlan(messages: [
            message(1, "me", minute: 0, delivery: .delivered),
            message(nil, "me", minute: 1, delivery: .sending),
        ], meID: "me")
        #expect(inFlight.entries.map(\.status) == [.delivered, .none])
        let landed = ConversationRunPlan(messages: [
            message(1, "me", minute: 0, delivery: .delivered),
            message(2, "me", minute: 1, delivery: .delivered),
        ], meID: "me")
        #expect(landed.entries.map(\.status) == [.none, .delivered])
    }

    @Test func aFailedNewerSendLeavesTheStatusOnTheLastDeliveredOne() {
        let plan = ConversationRunPlan(messages: [
            message(1, "me", minute: 0, delivery: .read(nil)),
            message(nil, "me", minute: 1, delivery: .failed("x")),
        ], meID: "me")
        #expect(plan.entries.map(\.status) == [.read(nil), .notDelivered])
    }

    @Test func onlyTheFirstMessageOfAnHourGapShowsATimestamp() {
        let plan = ConversationRunPlan(messages: [
            message(1, "a", minute: 0), message(2, "me", minute: 59), message(3, "a", minute: 120), message(4, "a", minute: 121),
        ], meID: "me")
        #expect(plan.entries.map(\.showsTimestamp) == [true, false, true, false])
    }

    /// Messages: a status row under a bubble ends its visual run, so the
    /// previous bubble keeps its tail while a newer send is in flight and
    /// hands it off only when the status moves (on delivery).
    @Test func aBubbleCarryingStatusKeepsItsTailUntilTheStatusMoves() {
        let inFlight = ConversationRunPlan(messages: [
            message(1, "me", minute: 0, delivery: .delivered),
            message(nil, "me", minute: 0.1, delivery: .sending),
        ], meID: "me")
        #expect(inFlight.entries.map(\.isLastInRun) == [true, true])
        let delivered = ConversationRunPlan(messages: [
            message(1, "me", minute: 0, delivery: .delivered),
            message(2, "me", minute: 0.1, delivery: .delivered),
        ], meID: "me")
        #expect(delivered.entries.map(\.isLastInRun) == [false, true])
    }
}
