import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Home says so when the person's last message in the Chief conversation has
/// had no reply for two minutes (user 2026-10-21: the Chief never forgets to
/// respond); a reply, a retraction or an agent's head clears it.
struct ChiefReplyWatchdogTests {
    static let sent = "2026-10-21T10:00:00.000Z"
    static let at = ChiefReplyWatchdog.date(sent)!

    static func summary(author: String, retracted: Bool = false) -> ConversationSummary {
        let message = ConversationMessage(id: "msg_1", conversation: "conv", seq: 1, clientMsgID: "c1", author: author,
                                          parts: [], createdAt: sent, retractedAt: retracted ? sent : nil)
        return ConversationSummary(id: "conv", title: "Chief",
                                   participants: [ConversationParticipant(id: "user_local", kind: .human, displayName: "Me"),
                                                  ConversationParticipant(id: "agent_mux", kind: .agent, displayName: "Chief",
                                                                          agentClass: "mux")],
                                   lastSeq: 1, rev: 1, createdAt: sent, updatedAt: sent, lastMessage: message)
    }

    @Test func noNoticeBeforeTwoMinutes() {
        let s = Self.summary(author: "user_local")
        #expect(ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(119)) == nil)
        #expect(ChiefReplyWatchdog.nextCheck(s, now: Self.at.addingTimeInterval(10)) == Self.at.addingTimeInterval(120))
    }

    @Test func noticeAfterTwoMinutesCountsTheMinutes() {
        let s = Self.summary(author: "user_local")
        let notice = ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(200))
        #expect(notice?.contains("3") == true)
        #expect(ChiefReplyWatchdog.nextCheck(s, now: Self.at.addingTimeInterval(200)) == Self.at.addingTimeInterval(240))
    }

    @Test func aReplyClearsIt() {
        let s = Self.summary(author: "agent_mux")
        #expect(ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(600)) == nil)
        #expect(ChiefReplyWatchdog.nextCheck(s, now: Self.at) == nil)
    }

    @Test func aRetractedMessageNeedsNoReply() {
        let s = Self.summary(author: "user_local", retracted: true)
        #expect(ChiefReplyWatchdog.notice(s, now: Self.at.addingTimeInterval(600)) == nil)
    }

    @Test func readsTimesWithoutMilliseconds() {
        #expect(ChiefReplyWatchdog.date("2026-10-21T10:00:00Z") == Self.at)
    }

    /// Foundation writes the minutes in the notice's own language, so no translation carries a minute noun
    /// that has to agree with the count (Arabic wrote the singular "دقيقة" after every count, wrong for 3 to 10
    /// and for 2). The language is pinned and the digits are Latin, so the host's language does not matter.
    @Test(arguments: [2, 3, 11, 100])
    func theNoticeWritesTheMinutesInItsOwnLanguage(minutes: Int) {
        let latin = Locale(identifier: "en_US@numbers=latn")
        #expect(HomeStrings.chiefNoReply(minutes: minutes, preferredLocalizations: ["en"], locale: latin)
            == "No reply from the Chief for \(minutes) min. It retries on its own and tells you if it cannot answer.")
        let arabic = HomeStrings.chiefNoReply(minutes: minutes, preferredLocalizations: ["ar"], locale: latin)
        let shortMinutes = Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .abbreviated)
            .locale(Locale(identifier: "ar_US@numbers=latn")))
        #expect(arabic.hasPrefix("لا رد من Chief"), "not the Arabic notice: \(arabic)")
        #expect(arabic.contains(shortMinutes + "."), "no Arabic short unit: \(arabic)")
        #expect(!arabic.contains("دقيقة") && !arabic.contains("دقائق"), "a minute noun after the count: \(arabic)")
        #expect(!arabic.contains("min"), "an English unit in the Arabic notice: \(arabic)")
    }

    /// A language cmux has no strings for reads the English notice with the English unit, not an English
    /// sentence around a unit in the person's language.
    @Test func anUnsupportedLanguageGetsTheEnglishUnitToo() {
        #expect(HomeStrings.chiefNoReply(minutes: 5, preferredLocalizations: ["he"], locale: Locale(identifier: "en_US@numbers=latn"))
            == "No reply from the Chief for 5 min. It retries on its own and tells you if it cannot answer.")
    }
}
