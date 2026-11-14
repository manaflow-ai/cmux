import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// User, Oct 20 (refs/imessage-layout/1.png): the grey thread connector beside a Chief reply ran
/// from the top of my message (a pasted block and two pictures above its text) down past every
/// bubble of it. In Messages the line links the reply to the bubble it answers, right above it:
/// it starts at that bubble and ends at the reply, at every width. HomeStore names the answered
/// message without a part (`PartRef(message:)`, part 0), so a several-part root anchors the line
/// on its last bubble. Each case maps HomeStore items through `ProjectionCore` and derives the
/// rows with `RowBuilder`.
@MainActor @Suite struct HomeReplyConnectorLengthTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_chief_connector")
    static let root = MessageID("msg_root")

    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }

    static let summary = ConversationSummary(
        id: id,
        participants: [
            CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
            CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
        ],
        lastSeq: 2, createdAt: date(-100), updatedAt: date(0))

    static let question = "optimize downloading update sizes, is that possible?"

    /// A root with several bubbles (a long block, a middle one, the question last) by `rootAuthor` and the
    /// Chief's thread reply to it. The line joins a reply and a root on the leading side only (user 2026-11-05,
    /// msg 23140), so the length cases root in a Chief message (an agent's report it answers in its thread).
    static func items(replyPart: Int?, rootAuthor: ParticipantID = chief) -> [TranscriptItem] {
        let block = (1...40).map { "Context line \($0) from the Chief." }.joined(separator: "\n")
        let rootItem = TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: rootAuthor,
                                      parts: [.text(block), .text("Claude Opus 5.5\nClaude Sonnet 5.5\nHaiku"),
                                              .text(question)],
                                      createdAt: date(2), delivery: .committed, messageID: root)
        let reply = TranscriptItem(key: IdempotencyKey("k2"), seq: 2, author: chief,
                                   parts: [.text("Yes, it's possible. Sparkle can ship binary deltas.")],
                                   createdAt: date(4), delivery: .committed,
                                   replyTo: replyPart.map { PartRef(message: root, partIndex: $0) } ?? PartRef(message: root),
                                   threadRoot: root, messageID: MessageID("msg_reply"))
        return [rootItem, reply]
    }

    /// The connector's root row key, its length, and the length from the root's last bubble.
    static func connector(width: CGFloat, replyPart: Int? = nil) throws -> (rootKey: String, length: CGFloat, lastBubbleKey: String, nearest: CGFloat) {
        var core = ProjectionCore(me: me)
        let (conv, _) = core.install(id, items: items(replyPart: replyPart), summary: summary)
        let rows = RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: date(60), width: width)
        var tops: [String: CGFloat] = [:], y: CGFloat = 0
        for r in rows { y += r.gap; tops[r.key] = y; y += r.height }
        let reply = try #require(rows.first { if case let .part(p) = $0.kind { p.connectorRoot != nil } else { false } })
        guard case let .part(p) = reply.kind, let rootKey = p.connectorRoot else { throw CancellationError() }
        let rootRow = try #require(rows.first { $0.key == rootKey })
        let replyIndex = try #require(rows.firstIndex(of: reply))
        let lastRootRow = try #require(rows.prefix(replyIndex).last { if case .part = $0.kind { true } else { false } })
        let bottom = try #require(tops[reply.key])
        let top = try #require(tops[rootKey]) + rootRow.height / 2
        let nearest = try #require(tops[lastRootRow.key]) + lastRootRow.height / 2
        return (rootKey, bottom - top, lastRootRow.key, bottom - nearest)
    }

    @Test(arguments: [CGFloat(320), 520, 760, 1100])
    func theLineStartsAtTheBubbleRightAboveTheReply(width: CGFloat) throws {
        let c = try Self.connector(width: width)
        #expect(c.rootKey == c.lastBubbleKey, "at \(width) pt the line starts at \(c.rootKey), not the bubble above the reply")
        #expect(c.length <= c.nearest + 0.5, "at \(width) pt the line is \(c.length) pt, the reply is \(c.nearest) pt under the bubble above it")
    }

    /// User 2026-11-05 (msg 23140): my root ends at the right edge, far from the arc's arm in the leading column, so the
    /// Chief's reply under it draws no arc (it hung over nothing).
    @Test(arguments: [CGFloat(320), 520, 760, 1100])
    func theChiefsReplyToMyRootDrawsNoStrayArc(width: CGFloat) {
        var core = ProjectionCore(me: Self.me)
        let (conv, _) = core.install(Self.id, items: Self.items(replyPart: nil, rootAuthor: Self.me), summary: Self.summary)
        let rows = RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: Self.date(60), width: width)
        #expect(!rows.contains { if case let .part(p) = $0.kind { p.connectorRoot != nil } else { false } })
    }

    /// A reply that names a later part of the root (a quote of that bubble) keeps that part.
    @Test func aNamedPartKeepsItsBubble() throws {
        let c = try Self.connector(width: 760, replyPart: 1)
        #expect(c.rootKey.hasSuffix(":1"))
    }
}
