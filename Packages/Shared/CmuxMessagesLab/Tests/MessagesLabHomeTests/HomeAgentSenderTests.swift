import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// An agent's message sent through its owner's CLI or MCP tool shows as the agent's own run in a
/// Chief chat: its name ("Grok bot › Ada") over the first bubble, its brand mark or monogram beside
/// the last, and no `[from …]` label in the bubble (u20190, Nov 3). Two bots in one chat get two
/// runs. A label typed by another person names nobody.
@MainActor @Suite struct HomeAgentSenderTests {
    typealias G = HomeGroupSenderTests

    static func item(_ seq: Int, author: ParticipantID = G.me, key: String, text: String) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey(key), seq: Seq(seq), author: author, parts: [.text(text)],
                       createdAt: G.date(Double(seq) * 2), delivery: .committed, messageID: MessageID("msg_\(seq)"))
    }

    /// A Chief chat where Grok bot › Ada and Muse talk through my CLI, and the Chief answers.
    static let twoBots: [TranscriptItem] = [
        item(1, key: "agent~grok-bot.ada~question~~n1", text: "[from Grok bot › Ada] Muse, can you take the review?"),
        item(2, key: "agent~muse~result~~n2", text: "[from Muse] Yes, on it."),
        item(3, author: G.chief, key: "k3", text: "Thanks, both."),
    ]

    @Test func twoBotsTalkingInAChiefChatShowTheirNamesAvatarsAndNoLabel() throws {
        var core = ProjectionCore(me: G.me)
        let (conv, _) = core.install(G.id, items: Self.twoBots, summary: G.summary([G.me, G.chief]))
        #expect(conv.cmuxGroup == true, "a chat with agent senders names their runs")
        let senders = conv.messages.map(\.senderId)
        #expect(senders == ["agent-sender:grok bot › ada", "agent-sender:muse", G.chief.rawValue])
        let texts = conv.messages.compactMap { m -> String? in
            if case let .text(t, _)? = m.parts.first { t } else { nil }
        }
        #expect(texts == ["Muse, can you take the review?", "Yes, on it.", "Thanks, both."])
        let people = Dictionary(uniqueKeysWithValues: conv.participants.map { ($0.id, $0) })
        #expect(people["agent-sender:grok bot › ada"]?.displayName == "Grok bot › Ada")
        #expect(people["agent-sender:grok bot › ada"]?.avatar == .brand("grok"))
        #expect(people["agent-sender:muse"]?.avatar == .brand("meta"), "Muse is Meta's Muse Code")

        let rows = RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: G.date(60))
        let names = rows.compactMap { row -> String? in
            if case let .senderName(n) = row.kind { n } else { nil }
        }
        #expect(names == ["Grok bot › Ada", "Muse", "Chief"])
        let avatars = rows.compactMap { row -> SenderAvatar? in
            if case let .part(p) = row.kind, !p.outgoing { p.cmuxAvatar } else { nil }
        }
        #expect(avatars.first == .brand("grok"))
        #expect(avatars.dropFirst().first == .brand("meta"))
    }

    @Test(arguments: [("Claude Code › 3fa9c1d2@mini", "claude"), ("Codex", "openai"), ("Grok bot", "grok"), ("Muse", "meta")])
    func knownAppsWearTheirBrandMark(label: String, brand: String) throws {
        let sender = try #require(HomeAgentSender(label: label))
        #expect(sender.avatar == .brand(brand))
    }

    @Test func aChiefAndAnUnknownBotWearAMonogram() throws {
        #expect(try #require(HomeAgentSender(label: "Docs Chief")).avatar == .monogram("CH"))
        #expect(try #require(HomeAgentSender(label: "Dot")).avatar == .monogram("D"))
        #expect(try #require(HomeAgentSender(label: "night shift › Ada")).avatar == .monogram("NS"))
    }

    @Test func aLabelAnotherPersonTypesNamesNobody() {
        let forged = Self.item(1, author: G.alice, key: "agent~muse~result~~n1", text: "[from Muse] hi")
        #expect(HomeAgentSender(forged, me: G.me) == nil)
        let unmarked = Self.item(2, key: "k2", text: "[from Muse] hi")
        #expect(HomeAgentSender(unmarked, me: G.me) == nil, "my own typed label is my words")
    }

    @Test func aNewBotInTheOpenChatAddsItsNameBeforeItsMessage() throws {
        var core = ProjectionCore(me: G.me)
        let first = Array(Self.twoBots.prefix(1))
        _ = core.install(G.id, items: first, summary: G.summary([G.me, G.chief]))
        let diff = core.step(items: Array(Self.twoBots.prefix(2)), summary: G.summary([G.me, G.chief]))
        guard case let .cmuxSetSenders(people, group)? = diff.actions.first else {
            Issue.record("the new sender comes first: \(diff.actions)")
            return
        }
        #expect(group)
        #expect(people.contains { $0.id == "agent-sender:muse" && $0.displayName == "Muse" })
    }
}
