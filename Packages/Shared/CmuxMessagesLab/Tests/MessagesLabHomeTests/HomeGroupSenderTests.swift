import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import MessagesLabHome

/// Group chats show who sent each message, as iMessage does: a small name
/// above the first bubble of each run of another person's messages, and that
/// person's avatar beside the last bubble of the run. My own messages, a
/// direct chat and a Chief chat show neither. Each case maps HomeStore items
/// through `ProjectionCore` (what `HomeProjection` installs), derives the
/// transcript rows with `RowBuilder` and draws the part rows with `RowDraw`.
@MainActor @Suite struct HomeGroupSenderTests {
    /// Nonisolated: `@Test(arguments:)` reads the ids outside the main actor.
    nonisolated static let me = ParticipantID("user_me")
    nonisolated static let alice = ParticipantID("user_alice")
    nonisolated static let bob = ParticipantID("user_bob")
    nonisolated static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_group")

    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }

    static let people: [ParticipantID: CmuxHomeCore.Participant] = [
        me: CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
        alice: CmuxHomeCore.Participant(id: alice, kind: .human, displayName: "Alice Smith"),
        bob: CmuxHomeCore.Participant(id: bob, kind: .human, displayName: "Bob Jones"),
        chief: CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief),
    ]

    static func summary(_ members: [ParticipantID]) -> ConversationSummary {
        ConversationSummary(id: id, participants: members.compactMap { people[$0] },
                            lastSeq: 5, createdAt: date(-100), updatedAt: date(0))
    }

    /// Messages 2 s apart (one run per sender), seq 1...
    static func items(_ authors: [ParticipantID]) -> [TranscriptItem] {
        authors.enumerated().map { i, author in
            let seq = Seq(i + 1)
            return TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: seq, author: author, parts: [.text("m\(seq)")],
                                  createdAt: date(Double(seq) * 2), delivery: .committed, messageID: MessageID("msg_\(seq)"))
        }
    }

    static func rows(members: [ParticipantID], authors: [ParticipantID]) -> [RowSpec] {
        var core = ProjectionCore(me: me)
        let (conv, _) = core.install(id, items: items(authors), summary: summary(members))
        return RowBuilder.rows(AppState(conversation: conv), messages: conv.messages, now: date(60))
    }

    /// The row's text: a bubble's text, or "name:<who>" for a sender name row.
    static func token(_ row: RowSpec) -> String? {
        if row.key.hasPrefix("name:") {
            let drawn = "\(row.kind)"
            let who = ["Alice Smith", "Bob Jones", "Chief", "Me"].first { drawn.contains($0) } ?? "?"
            return "name:\(who)"
        }
        if case let .part(p) = row.kind, case let .text(t, _) = p.part { return t }
        return nil
    }

    /// Whether the row's bitmap has pixels in the column left of its bubble (and its tail):
    /// where the sender's avatar draws.
    static func drawsBesideBubble(_ spec: RowSpec) throws -> Bool {
        let body = RowDraw.bodyRect(spec)
        let size = CGSize(width: spec.width, height: spec.height + 2 * RowDraw.margin)
        let image = try #require(WideBitmap.make(size: size, scale: 1, opaque: false) { ctx in
            RowDraw.drawStatic(spec, ctx, windowY: .nan)
        })
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            // SAFETY: buf is the array's storage, w * h * 4 bytes (its count), lent for this closure; the context writes
            // w * 4 bytes a row for h rows inside it, and is not drawn into after the closure.
            guard let ctx = unsafe CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        #expect(drawn)
        // Image rows run top to bottom in memory; the column stops 8 pt left of the body (the tail's reach).
        let maxX = min(w, Int((body.minX - 8).rounded(.down)))
        let rowsRange = max(0, Int(body.minY))..<min(h, Int(body.maxY.rounded(.up)))
        guard maxX > 0 else { return false }
        for y in rowsRange {
            for x in 0..<maxX where pixels[(y * w + x) * 4 + 3] > 8 { return true }
        }
        return false
    }

    @Test func aGroupNamesTheFirstBubbleOfEachRunFromSomeoneElse() {
        let rows = Self.rows(members: [Self.me, Self.alice, Self.bob],
                             authors: [Self.alice, Self.alice, Self.bob, Self.me, Self.alice])
        let tokens = rows.compactMap(Self.token)
        #expect(tokens == ["name:Alice Smith", "m1", "m2", "name:Bob Jones", "m3", "m4", "name:Alice Smith", "m5"],
                "rows: \(rows.map(\.key))")
    }

    @Test func aGroupDrawsTheAvatarBesideTheLastBubbleOfEachIncomingRun() throws {
        let rows = Self.rows(members: [Self.me, Self.alice, Self.bob],
                             authors: [Self.alice, Self.alice, Self.bob, Self.me, Self.alice])
        var beside: [String: Bool] = [:]
        for row in rows {
            guard case let .part(p) = row.kind, case let .text(t, _) = p.part, !p.outgoing else { continue }
            beside[t] = try Self.drawsBesideBubble(row)
        }
        #expect(beside == ["m1": false, "m2": true, "m3": true, "m5": true])
    }

    @Test(arguments: [[HomeGroupSenderTests.me, HomeGroupSenderTests.alice], [HomeGroupSenderTests.me, HomeGroupSenderTests.chief]])
    func aDirectOrChiefChatShowsNoNamesOrAvatars(members: [ParticipantID]) throws {
        let other = try #require(members.last)
        let rows = Self.rows(members: members, authors: [other, other, Self.me, other])
        #expect(!rows.contains { $0.key.hasPrefix("name:") }, "rows: \(rows.map(\.key))")
        for row in rows {
            guard case let .part(p) = row.kind, !p.outgoing else { continue }
            #expect(RowDraw.bodyRect(row).minX == Fixture.leftEdge)
            #expect(try !Self.drawsBesideBubble(row), "row \(row.key)")
        }
    }
}
