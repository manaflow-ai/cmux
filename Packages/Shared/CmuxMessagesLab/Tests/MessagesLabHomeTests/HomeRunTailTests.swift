import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Messages draws the tail only on the last bubble of a run of one sender's messages; the bubbles above it are
/// plain rounded bubbles 3 pt apart, and a new run starts 8 pt under the last one (user, 2026-11-04, Home's welcome
/// next to the same text in Messages: "only the last message has the bottom left message indicator thing"). Chief's
/// first-launch welcome once drew each of its three bubbles with its own tail, 14 pt apart.
@MainActor @Suite struct HomeRunTailTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let chief = ParticipantID("agent_mux")
    static let me = ParticipantID("user_local")

    static var summary: ConversationSummary {
        let people = [CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        return ConversationSummary(id: ConversationID("c"), title: "Chief", participants: people, lastSeq: 3,
                                   createdAt: t0, updatedAt: t0, readCursors: [:], readCursorTimes: [:])
    }

    /// Chief's welcome bubble `n`, mapped as Home maps it (CmuxNext `ChiefWelcome` client ids "chief-welcome-…").
    static func welcome(_ n: Int) -> MessagesLabHome.Message {
        let item = TranscriptItem(key: IdempotencyKey("\(HomeMapping.welcomeKeyPrefix)\(n)"), seq: Seq(n), author: chief,
                                  parts: [.text("welcome \(n)")], createdAt: t0.addingTimeInterval(Double(n)),
                                  delivery: .committed, messageID: MessageID("w\(n)"))
        return HomeMapping.message(item, aliases: [:], me: me, summary: summary)
    }

    static func message(_ id: String, from sender: String, at seconds: Double) -> MessagesLabHome.Message {
        MessagesLabHome.Message(id: id, senderId: sender, sentAt: Instant.format(t0.addingTimeInterval(seconds)),
                parts: [.text("hello there", runs: [])], replyTo: nil, status: nil, edits: nil, retractedAt: nil, reactions: [])
    }

    static func rows(_ messages: [MessagesLabHome.Message], group: Bool = false) -> [RowSpec] {
        var conversation = Conversation(id: "c", title: "Chief", participants: [
            MessagesLabHome.Participant(id: me.rawValue, displayName: "Me", isMe: true, avatar: nil),
            MessagesLabHome.Participant(id: chief.rawValue, displayName: "Chief", isMe: false, avatar: nil),
            MessagesLabHome.Participant(id: "ann", displayName: "Ann", isMe: false, avatar: .monogram("A")),
        ], messages: messages)
        if group { conversation.cmuxGroup = true }
        return RowBuilder.rows(AppState(conversation: conversation), messages: messages, now: t0.addingTimeInterval(10))
    }

    static func bubbles(_ rows: [RowSpec]) -> [(gap: CGFloat, tail: Bool, avatar: Bool)] {
        rows.compactMap { row in
            guard case let .part(spec) = row.kind else { return nil }
            return (row.gap, spec.tail, spec.cmuxAvatar != nil)
        }
    }

    @Test func welcomeIsOneRunWithOneTail() {
        let bubbles = Self.bubbles(Self.rows((1...3).map(Self.welcome)))
        #expect(bubbles.map(\.tail) == [false, false, true])
        #expect(bubbles.dropFirst().map(\.gap) == [3, 3])
    }

    @Test func theLastBubbleGivesItsTailToANewArrival() {
        #expect(Self.bubbles(Self.rows((1...2).map(Self.welcome))).map(\.tail) == [false, true])
        #expect(Self.bubbles(Self.rows((1...3).map(Self.welcome))).map(\.tail) == [false, false, true])
    }

    @Test func myRunHasOneTailToo() {
        let mine = (0..<3).map { Self.message("m\($0)", from: Self.me.rawValue, at: Double($0)) }
        let bubbles = Self.bubbles(Self.rows(mine))
        #expect(bubbles.map(\.tail) == [false, false, true])
        #expect(bubbles.dropFirst().map(\.gap) == [3, 3])
    }

    @Test func aSenderChangeEndsTheRun() {
        let messages = [Self.message("a", from: Self.chief.rawValue, at: 0), Self.message("b", from: Self.chief.rawValue, at: 1),
                        Self.message("c", from: Self.me.rawValue, at: 2), Self.message("d", from: Self.me.rawValue, at: 3)]
        let bubbles = Self.bubbles(Self.rows(messages))
        #expect(bubbles.map(\.tail) == [false, true, false, true])
        #expect(bubbles.dropFirst().map(\.gap) == [3, 8, 3])
    }

    @Test func aGroupChatRunHasOneTailAndOneAvatar() {
        let messages = [Self.message("a", from: "ann", at: 0), Self.message("b", from: "ann", at: 1),
                        Self.message("c", from: "ann", at: 2)]
        let bubbles = Self.bubbles(Self.rows(messages, group: true))
        #expect(bubbles.map(\.tail) == [false, false, true])
        #expect(bubbles.map(\.avatar) == [false, false, true])
    }
}
