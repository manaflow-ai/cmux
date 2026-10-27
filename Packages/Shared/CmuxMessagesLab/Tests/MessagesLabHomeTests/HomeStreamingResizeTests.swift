import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A divider drag or window resize while the Chief's reply streams never shows my bubbles past the
/// transcript's right edge (Lawrence and u2891, 2026-10-19: "user bubbles clipped at right edge").
///
/// The cause: the transcript runs one width pass per display frame; a later width change in the same
/// frame waits for the next frame's tick when the frame's passes already cost the frame budget
/// (`MessagesWindowView.widthPassFrameBudget`). While a reply streams, every chunk changed
/// `state.ui.streams`, so a width pass could not reuse the last width change's rows and derived the
/// rows of every loaded message again: each pass of a drag was long, the next width change waited,
/// and the frame showed the rows of the older, wider width in the narrower view. My bubbles sit at
/// the right edge of the width they were laid out for, so they showed cut off.
///
/// The rules this checks, with display frames the test starts itself (an offscreen view has no
/// display link): (1) at the end of every frame no row is laid out wider than the view, at any frame
/// budget; (2) while a reply streams, a width pass re-measures the kept rows and derives only the
/// newest message's rows and the stream again, not every loaded message.
@MainActor @Suite(.serialized) struct HomeStreamingResizeTests {
    /// These tests make a `MessagesWindowView` without a Home pane: springs.json comes from the package, as
    /// `HomeMarkdownPolicy.install()` sets it for a pane (Springs.swift fails loudly without it, MessagesLab cdee8d9).
    init() { HomeMarkdownPolicy.installSprings() }

    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_chief")
    static let id = ConversationID("conv_stream_resize")
    static let turn = IdempotencyKey("turn_resize")

    /// The display frames: next-frame work waits here until the test starts the next frame.
    final class Frames {
        var work: [() -> Void] = []
        func start() {
            let now = work
            work.removeAll()
            now.forEach { $0() }
        }
    }

    struct Rig {
        let view: MessagesWindowView
        let store: Store
        let frames: Frames
        var core: ProjectionCore
        var text = ""
    }

    static func rig(messages: Int, width: CGFloat) -> Rig {
        DisplayScale.current = 2
        Fixture.renderScale = 2
        RowCell.synchronousBitmaps = false
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let people = [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let items = (1...messages).map { i in
            let mine = i % 2 == 0
            let text = mine
                ? "Message \(i): make sure we have proper Sentry crash analytics set up so everything is observable to us."
                : "Reply \(i): the new path deletes the old switching code and writes it again in one place."
            return TranscriptItem(key: IdempotencyKey("k\(i)"), seq: Seq(i), author: mine ? me : chief, parts: [.text(text)],
                                  createdAt: base.addingTimeInterval(Double(i) * 30), delivery: .committed, messageID: MessageID("msg_\(i)"))
        }
        let summary = ConversationSummary(id: id, title: "Chief", participants: people, lastSeq: Seq(messages),
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: me)
        core.replies = .streaming // the stream bubbles (HomeReplyDisplay)
        let (conv, w) = core.install(id, items: items, summary: summary)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        let view = MessagesWindowView(store: store)
        let frames = Frames()
        view.widthFrameScheduler = { [frames] f in frames.work.append(f) }
        view.clock = { [weak store] in store?.now ?? 0 }
        view.layer.speed = 0
        view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        view.layoutIfNeeded()
        view.collection.layoutIfNeeded()
        return Rig(view: view, store: store, frames: frames, core: core)
    }

    /// The Chief's reply streams one more chunk (the whole reply so far, as HomeStore holds it).
    static func stream(_ rig: inout Rig, _ chunk: String) {
        rig.text += chunk
        let row = HomeStreamRow(turn: turn, author: chief, text: rig.text)
        for action in rig.core.streams([row], state: rig.store.state) { rig.store.dispatch(action) }
    }

    /// One width change as a divider drag makes it: the frame only, then AppKit's layout pass.
    static func resize(_ rig: Rig, to width: CGFloat) {
        rig.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        rig.view.layoutIfNeeded()
        rig.view.collection.layoutIfNeeded()
    }

    /// The widest width a shown row of the transcript was laid out for (a ghost is a row fading out at its old place).
    static func widestRow(_ view: MessagesWindowView) -> CGFloat { view.model.rows.filter { !$0.ghost }.map(\.spec.width).max() ?? 0 }

    /// My bubbles' right edges past the view's width.
    static func clipped(_ view: MessagesWindowView) -> [CGFloat] {
        view.model.rows.compactMap { row in
            guard case let .part(p) = row.spec.kind, p.outgoing else { return nil }
            let right = row.spec.metrics.rightEdge
            return right > view.bounds.width + 0.5 ? right : nil
        }
    }

    /// A drag from 1200 pt down to 480 pt and back while the reply streams, three width changes per
    /// frame (the mouse moves faster than the display), one chunk per frame. Returns the frames that
    /// ended with rows wider than the view, and the main-thread time of each frame.
    static func drag(_ rig: inout Rig) -> (stale: [String], ms: [Double]) {
        var stale: [String] = [], ms: [Double] = []
        let widths = Array(stride(from: 1200.0, through: 480.0, by: -12.0)) + Array(stride(from: 480.0, through: 1200.0, by: 12.0))
        var i = 0, frame = 0
        while i < widths.count {
            let t0 = CACurrentMediaTime()
            rig.frames.start()
            stream(&rig, " and \(frame)")
            for w in widths[i..<min(widths.count, i + 3)] { resize(rig, to: CGFloat(w)) }
            ms.append((CACurrentMediaTime() - t0) * 1000)
            // The frame is shown now: no row may be wider than the view.
            let widest = widestRow(rig.view), shown = rig.view.bounds.width
            if widest > shown + 0.5 { stale.append("frame \(frame): rows for \(widest) pt in \(shown) pt, clipped \(clipped(rig.view))") }
            i += 3
            frame += 1
        }
        rig.frames.start()
        return (stale, ms)
    }

    private static func p(_ xs: [Double], _ q: Double) -> Double {
        let s = xs.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
    }

    /// A slow frame (budget 0: every frame's first pass uses the whole budget) defers the frame's later
    /// width changes: a narrower one must still lay the rows out at once, so no bubble is cut off.
    @Test func aSlowFrameNeverShowsRowsWiderThanTheView() {
        let saved = MessagesWindowView.widthPassFrameBudget
        MessagesWindowView.widthPassFrameBudget = 0
        defer { MessagesWindowView.widthPassFrameBudget = saved }
        var rig = Self.rig(messages: 120, width: 1200)
        Self.stream(&rig, "I restarted everything")
        let (stale, _) = Self.drag(&rig)
        #expect(stale.isEmpty, "\(stale.count) frames showed rows wider than the view: \(stale.prefix(5))")
    }

    /// While a reply streams, each width pass reuses the rows of the last one (re-measured) and derives
    /// only the newest message and the stream: one full derivation for the whole drag, not one per frame.
    @Test func aStreamingReplyKeepsTheWidthPassFast() {
        var rig = Self.rig(messages: 400, width: 1200)
        Self.stream(&rig, "I restarted everything")
        let full0 = MessagesWindowView.widthRowsDerived
        let (stale, ms) = Self.drag(&rig)
        let full = MessagesWindowView.widthRowsDerived - full0
        print(String(format: "STREAMRESIZE frames %d p50 %.2f p95 %.2f max %.2f ms, full derivations %d, deferred %d, stale %d",
                     ms.count, Self.p(ms, 0.5), Self.p(ms, 0.95), ms.max() ?? 0, full, MessagesWindowView.widthPassesDeferred, stale.count))
        #expect(full <= 1, "\(full) width passes derived every loaded message again while the reply streamed")
        #expect(stale.isEmpty, "\(stale.count) frames showed rows wider than the view: \(stale.prefix(5))")
        // The rows the fast path kept equal a full derivation at the same width (keys, heights, widths).
        let st = rig.store.state
        let fresh = RowBuilder.rows(st, messages: st.conversation.messages, now: rig.store.date(at: rig.view.clock()),
                                    width: rig.view.bounds.width, scale: Fixture.renderScale)
        // The trailing rows (typing, the stream, the notice) follow their own transitions; the message rows must match.
        let shown = rig.view.model.rows.filter { !$0.ghost }.map(\.spec)
        let keys = { (rows: [RowSpec]) in rows.map(\.key).filter { !RowBuilder.isTrailing($0) } }
        #expect(keys(shown) == keys(fresh), "the kept rows are not the rows of the current state")
        #expect(shown.allSatisfy { $0.width == rig.view.bounds.width })
    }
}
