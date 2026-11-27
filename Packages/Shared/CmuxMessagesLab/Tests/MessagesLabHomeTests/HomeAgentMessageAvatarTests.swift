import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// User 2026-11-02 (msg 19633): "chief icon is bouncing in imessage ui". In a chat with the Chief and
/// a teammate, the Chief's avatar sits beside the last bubble of its run (iMessage). The Chief's
/// messages to its agents and their reports (`HomeAgentMessages` rows) are authored by the Chief, so
/// each one that arrived, folded or opened took the avatar off the Chief's reply or put it on another
/// row: the avatar jumped between rows as they came. They are asides now: the avatar stays beside the
/// Chief's own reply, and no agent row draws the avatar or the sender's name.
@MainActor @Suite struct HomeAgentMessageAvatarTests {
    typealias G = HomeGroupSenderTests
    static let replyKey = IdempotencyKey("k2")

    /// My question, then the Chief's reply, in a chat with Alice (a group: avatars and names show).
    static func base() -> [TranscriptItem] {
        [TranscriptItem(key: IdempotencyKey("k1"), seq: Seq(1), author: G.me, parts: [.text("What did you tell the agents?")],
                        createdAt: G.date(2), delivery: .committed, messageID: MessageID("msg_1")),
         TranscriptItem(key: replyKey, seq: Seq(2), author: G.chief, parts: [.text("I told three agents.")],
                        createdAt: G.date(4), delivery: .committed, messageID: MessageID("msg_2"))]
    }

    /// An agent-message row as `HomeAgentMessages` inserts it under the reply, `offset` seconds after it.
    static func agentRow(_ id: String, _ kind: HomeAgentMessageRow.Kind, offset: Double) -> TranscriptItem {
        var item = TranscriptItem(key: IdempotencyKey("agent-message:\(G.chief.rawValue):run:\(id)"), seq: nil, author: G.chief,
                                  parts: [.text(id)], createdAt: G.date(4 + offset), delivery: .committed)
        item.isReadOnly = true
        item.agentMessage = HomeAgentMessageRow(group: "0123456789abcdef", kind: kind)
        return item
    }

    static func tell(_ id: String, offset: Double) -> TranscriptItem {
        agentRow(id, .message(from: "Chief", to: id, outgoing: true, text: "please check \(id)"), offset: offset)
    }

    static func fold(count: Int, peers: [String], expanded: Bool) -> TranscriptItem {
        var item = agentRow("fold", .fold(count: count, peers: peers, expanded: expanded), offset: 1)
        item.key = IdempotencyKey("agent-messages:0123456789abcdef")
        return item
    }

    /// The message ids whose rows draw an avatar, and the message ids under a sender-name row.
    static func layout(_ items: [TranscriptItem]) -> (avatars: [ID], names: [ID]) {
        HomeAgentFoldRowProvider.install()
        var core = ProjectionCore(me: G.me)
        let (conv, _) = core.install(G.id, items: items, summary: G.summary([G.me, G.alice, G.chief]))
        var avatars: [ID] = [], names: [ID] = []
        for row in RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: G.date(60)) {
            if case let .part(p) = row.kind, p.cmuxAvatar != nil { avatars.append(p.ref.messageId) }
            if row.key.hasPrefix("name:") { names.append(String(row.key.dropFirst("name:".count))) }
        }
        return (avatars, names)
    }

    static var replyID: ID { HomeMapping.id(Self.base()[1], aliases: [:]) }

    @Test func theChiefsAvatarStaysBesideItsReplyWhileAgentRowsArriveFoldAndOpen() {
        // As the run streams in: no agent row yet, one tell (a bubble), two (one fold row), then
        // the fold opened (the row and both bubbles), then closed again.
        let states: [(String, [TranscriptItem])] = [
            ("reply alone", Self.base()),
            ("one tell", Self.base() + [Self.tell("a959", offset: 1)]),
            ("folded", Self.base() + [Self.fold(count: 2, peers: ["a959", "a931"], expanded: false)]),
            ("opened", Self.base() + [Self.fold(count: 2, peers: ["a959", "a931"], expanded: true),
                                 Self.tell("a959", offset: 1), Self.tell("a931", offset: 2)]),
            ("closed", Self.base() + [Self.fold(count: 2, peers: ["a959", "a931"], expanded: false)]),
        ]
        for (name, items) in states {
            let drawn = Self.layout(items)
            #expect(drawn.avatars == [Self.replyID], "\(name): the avatar is beside \(drawn.avatars), not only the Chief's reply")
            #expect(drawn.names == [Self.replyID], "\(name): a sender name above \(drawn.names), not only the reply's run")
        }
    }

    @Test func aRealChiefMessageAfterTheAgentRowsTakesTheAvatarAsANewRun() {
        var next = TranscriptItem(key: IdempotencyKey("k3"), seq: Seq(3), author: G.chief, parts: [.text("All three reported.")],
                                  createdAt: G.date(9), delivery: .committed, messageID: MessageID("msg_3"))
        next.replyTo = nil
        let items = Self.base() + [Self.fold(count: 2, peers: ["a959", "a931"], expanded: false), next]
        let drawn = Self.layout(items)
        let nextID = HomeMapping.id(next, aliases: [:])
        #expect(drawn.avatars == [Self.replyID, nextID])
    }
}
