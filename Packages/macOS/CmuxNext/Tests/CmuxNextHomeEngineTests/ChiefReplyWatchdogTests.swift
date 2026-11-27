import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Home says so when the person's last message in the Chief conversation has waited two
/// minutes and the Chief's brain is not running (user 2026-10-21: the Chief never forgets
/// to respond). A running brain answers or says why it cannot, so its slowness shows nothing
/// (Leo, 2026-11-03: "don't fucking show no response from model"); a reply, a retraction, an
/// agent's head or another agent's `cmux chief -p` message clears it.
struct ChiefReplyWatchdogTests {
    static let sent = "2026-10-21T10:00:00.000Z"
    static let at = ChiefReplyWatchdog.date(sent)!

    static func summary(author: String, retracted: Bool = false, clientMsgID: String = "c1") -> ConversationSummary {
        let message = ConversationMessage(id: "msg_1", conversation: "conv", seq: 1, clientMsgID: clientMsgID, author: author,
                                          parts: [], createdAt: sent, retractedAt: retracted ? sent : nil)
        return ConversationSummary(id: "conv", title: "Chief",
                                   participants: [ConversationParticipant(id: "user_local", kind: .human, displayName: "Me"),
                                                  ConversationParticipant(id: "agent_mux", kind: .agent, displayName: "Chief",
                                                                          agentClass: "mux")],
                                   lastSeq: 1, rev: 1, createdAt: sent, updatedAt: sent, lastMessage: message)
    }

    @Test func noNoticeBeforeTwoMinutes() {
        let s = Self.summary(author: "user_local")
        #expect(ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(119), brainRunning: false) == nil)
        #expect(ChiefReplyWatchdog.nextCheck(s, now: Self.at.addingTimeInterval(10)) == Self.at.addingTimeInterval(120))
    }

    @Test func aStoppedBrainIsNamedAfterTwoMinutes() {
        let s = Self.summary(author: "user_local")
        #expect(ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(200), brainRunning: false)
            == HomeStrings.chiefNotRunning)
        #expect(ChiefReplyWatchdog.nextCheck(s, now: Self.at.addingTimeInterval(200)) == Self.at.addingTimeInterval(240))
    }

    @Test func aRunningBrainsSlownessShowsNothing() {
        let s = Self.summary(author: "user_local")
        #expect(ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(600), brainRunning: true) == nil)
    }

    @Test func anotherAgentsMessageNeedsNoNotice() {
        let s = Self.summary(author: "user_local", clientMsgID: "agent~claude-sr2-coord~result~~abc123")
        #expect(ChiefReplyWatchdog.waitingSince(s) == nil)
        #expect(ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(600), brainRunning: false) == nil)
    }

    @Test func aReplyClearsIt() {
        let s = Self.summary(author: "agent_mux")
        #expect(ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(600), brainRunning: false) == nil)
        #expect(ChiefReplyWatchdog.nextCheck(s, now: Self.at) == nil)
    }

    @Test func aRetractedMessageNeedsNoReply() {
        let s = Self.summary(author: "user_local", retracted: true)
        #expect(ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(600), brainRunning: false) == nil)
    }

    @Test func readsTimesWithoutMilliseconds() {
        #expect(ChiefReplyWatchdog.date("2026-10-21T10:00:00Z") == Self.at)
    }
}
