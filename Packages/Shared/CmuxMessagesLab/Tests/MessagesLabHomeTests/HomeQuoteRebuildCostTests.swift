import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The Home chat's row re-derivation stays cheap in a long chat full of thread replies (user, 2026-10-31: "in imessage ui
/// cmux has hung many times for day (beach balling) ... fix all").
///
/// The NIGHTLY's hang log (~/Library/Logs/com.cmuxterm.app.nightly/hangs, Oct 30-31) holds five 2.7-4.4 s main-thread
/// hangs in one path: a picture or link image finishes loading (`HomeMedia.onReady`), `HomeProjection.refreshAttachments`
/// dispatches `.cmuxSetAttachment` / `.linkMetadata`, and the commit re-derives every row from that message to the end
/// (`.linkMetadata`: every row) with `RowBuilder.rows`, which lays out every reply's quote of its root with Core Text again
/// (`ThreadPreview.make` -> `wrap` / `truncate`) and finds each root by a scan of every loaded message.
///
/// Rule: with every bubble already measured (`MeasureCache` warm, as after the first layout), re-deriving all rows of a
/// 1,200-message chat in which every third message is a reply quoting a long root costs under 75 ms at p50 (fleet minis:
/// 232-251 ms before the quote cache, 19-38 ms after), the time a picture arriving may take on the main thread. `HOMEQUOTE` lines in the log carry the numbers.
@MainActor @Suite(.serialized) struct HomeQuoteRebuildCostTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_quote_cost")
    static let width: CGFloat = 628

    static func date(_ t: Double) -> Date { Replay.base.addingTimeInterval(t) }

    /// A root as the Chief writes them: several sentences, a long URL, a path; 5 to 12 quote lines at 10 pt.
    static func root(_ n: Int) -> String {
        let reps = 2 + n % 4
        return (0..<reps).map { k in
            "a\(900 + n) step \(k): landed the fix on feat-cmux-next, see https://github.com/manaflow-ai/cmux/compare/"
                + "aaaaaaaaaaaa\(n)\(k)...bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\(n) and the shots in "
                + "~/fun/cmux-shots/home-quote-\(n)/frame-\(k).png; before p95 \(n % 40 + 20) ms, after \(n % 7 + 2) ms."
        }.joined(separator: "\n")
    }

    static func conversation(messages count: Int) -> Conversation {
        let summary = ConversationSummary(
            id: id,
            participants: [
                CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief"),
            ],
            lastSeq: Seq(count), createdAt: date(-100), updatedAt: date(Double(count) * 30))
        var roots: [MessageID] = []
        var items: [TranscriptItem] = []
        for seq in 1...count {
            let mid = MessageID("msg_\(seq)")
            let author = seq % 2 == 0 ? me : chief
            if seq % 3 == 0, !roots.isEmpty {
                let r = roots[(seq / 3) % roots.count]
                items.append(TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: Seq(seq), author: author, parts: [.text("ok, on it \(seq)")],
                                            createdAt: date(Double(seq) * 30), delivery: .committed, replyTo: CmuxHomeCore.PartRef(message: r),
                                            threadRoot: r, messageID: mid))
            } else {
                roots.append(mid)
                items.append(TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: Seq(seq), author: author, parts: [.text(root(seq))],
                                            createdAt: date(Double(seq) * 30), delivery: .committed, messageID: mid))
            }
        }
        var core = ProjectionCore(me: me)
        return core.install(id, items: items, summary: summary).0
    }

    @Test func rederivingEveryRowOfALongThreadedChatStaysUnder75ms() {
        let conv = Self.conversation(messages: 1200)
        let state = AppState(conversation: conv)
        func derive() -> [RowSpec] {
            Fixture.withRenderScale(2) {
                RowBuilder.rows(state, messages: conv.messages, now: Self.date(Double(conv.messages.count) * 30 + 60), width: Self.width, scale: 2)
            }
        }
        // The first pass measures every bubble (the chat's first layout, not a picture arriving).
        let first = derive()
        let quotes = first.filter { if case .threadPreview = $0.kind { return true }; return false }.count
        #expect(quotes >= 300, "the fixture quotes a root in every third message (\(quotes) quotes)")
        var times: [Double] = []
        for _ in 0..<15 {
            let t0 = CACurrentMediaTime()
            let rows = derive()
            times.append((CACurrentMediaTime() - t0) * 1000)
            #expect(rows.count == first.count)
        }
        let p50 = HomeStreamingPerfTests.p(times, 0.5), p95 = HomeStreamingPerfTests.p(times, 0.95)
        print(String(format: "HOMEQUOTE rederive messages %d quotes %d rows %d p50 %.2f p95 %.2f max %.2f ms",
                     conv.messages.count, quotes, first.count, p50, p95, times.max() ?? 0))
        #expect(p50 < 75, "re-deriving every row costs \(p50) ms at p50 (a picture arriving blocks the main thread that long)")
    }

    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// Pictures that load together (a chat's open, `HomeProjection.refreshAttachments()`) reach the transcript as one
    /// `.cmuxSetAttachments` commit: every row below the oldest is re-derived once, not once per picture. The 40 one-picture
    /// commits the projection used to dispatch are timed beside it (`HOMEQUOTE pictures` line).
    @Test func picturesThatLoadTogetherCostOneCommit() throws {
        var items: [TranscriptItem] = []
        let count = 1200
        var roots: [MessageID] = []
        for seq in 1...count {
            let mid = MessageID("msg_\(seq)")
            let author = seq % 2 == 0 ? Self.me : Self.chief
            let at = Self.date(Double(seq) * 30)
            if seq % 30 == 0 {
                let ref = AttachmentRef(hash: "hash_\(seq)", name: "shot-\(seq).png", mimeType: "image/png", byteCount: 90_000, width: 1200, height: 800)
                items.append(TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: Seq(seq), author: author, parts: [.attachment(ref)], createdAt: at,
                                            delivery: .committed, messageID: mid))
            } else if seq % 3 == 0, !roots.isEmpty {
                let r = roots[(seq / 3) % roots.count]
                items.append(TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: Seq(seq), author: author, parts: [.text("ok, on it \(seq)")],
                                            createdAt: at, delivery: .committed, replyTo: CmuxHomeCore.PartRef(message: r), threadRoot: r, messageID: mid))
            } else {
                roots.append(mid)
                items.append(TranscriptItem(key: IdempotencyKey("k\(seq)"), seq: Seq(seq), author: author, parts: [.text(Self.root(seq))],
                                            createdAt: at, delivery: .committed, messageID: mid))
            }
        }
        let summary = ConversationSummary(
            id: Self.id,
            participants: [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                           CmuxHomeCore.Participant(id: Self.chief, kind: .agent, displayName: "Chief")],
            lastSeq: Seq(count), createdAt: Self.date(-100), updatedAt: Self.date(Double(count) * 30))
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(Self.id, items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 900)), wake: NoWake())
        window.contentView = controller.host
        controller.install(conv, windowStart: w.start, total: w.total)
        controller.host.layoutSubtreeIfNeeded()
        let store = try #require(controller.store)
        func pictures(_ transfer: MessagesLabHome.Attachment.Transfer) -> [(id: ID, attachment: MessagesLabHome.Attachment)] {
            store.state.conversation.messages.compactMap { m in
                guard case var .attachment(a)? = m.parts.first else { return nil }
                a.transfer = transfer
                return (id: m.id, attachment: a)
            }
        }
        let loaded = pictures(.downloading(0.5))
        #expect(loaded.count >= 30, "the window holds the chat's pictures (\(loaded.count))")
        // Before: one commit per picture, as refreshAttachments dispatched them.
        var t0 = CACurrentMediaTime()
        for update in loaded { controller.dispatch(.cmuxSetAttachments([update])) }
        let singles = (CACurrentMediaTime() - t0) * 1000
        // After: one commit for the refresh.
        let done = pictures(.done)
        t0 = CACurrentMediaTime()
        controller.dispatch(.cmuxSetAttachments(done))
        let batch = (CACurrentMediaTime() - t0) * 1000
        #expect(pictures(.done).allSatisfy { u in store.state.conversation.messages.contains { m in
            if case let .attachment(a)? = m.parts.first, m.id == u.id { return a.transfer == .done }; return false } })
        print(String(format: "HOMEQUOTE pictures %d one-per-picture %.2f ms, one batch %.2f ms", loaded.count, singles, batch))
        #expect(batch < 150, "one refresh of \(loaded.count) pictures blocks the main thread \(batch) ms")
        #expect(batch * 5 < singles, "one commit (\(batch) ms) costs a fraction of one per picture (\(singles) ms)")
    }

    /// A quote's lines and box are the same whether laid out the first time or taken again on a later re-derivation.
    @Test func aQuoteLaysOutTheSameEveryTime() {
        let text = Self.root(7)
        let a = ThreadPreview.make(root: MessagesLabHome.PartRef(messageId: "m", partIndex: 0), part: .text(text, runs: []), count: 2, width: Self.width)
        let b = ThreadPreview.make(root: MessagesLabHome.PartRef(messageId: "m", partIndex: 0), part: .text(text, runs: []), count: 2, width: Self.width)
        let narrow = ThreadPreview.make(root: MessagesLabHome.PartRef(messageId: "m", partIndex: 0), part: .text(text, runs: []), count: 2, width: 420)
        #expect(a == b)
        #expect(a.textLines.count == ThreadPreview.maxTextLines)
        #expect(a.textLines.last?.hasSuffix("…") == true)
        #expect(narrow.box.width < a.box.width, "a narrower transcript wraps the quote narrower")
    }
}
