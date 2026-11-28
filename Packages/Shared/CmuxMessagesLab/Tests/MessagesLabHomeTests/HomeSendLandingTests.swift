import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A long message I send lands as a bubble that wraps inside the text column
/// at the pane's width, and no flying copy of it outlives the send animation
/// (Lawrence 2026-10-19: his long messages showed cut off at the pane's right
/// edge, "You should always r"). The suspect was the send's flying bubble
/// keeping the field's one-line shape; this passed before any change, so it is a
/// guard, not the cause. Covers a send at the pane's width and a pane resized
/// while the bubble flies. Offscreen window view on a virtual clock
/// (the HarnessTests loop).
@MainActor @Suite(.serialized) struct HomeSendLandingTests {
    /// These tests make a `MessagesWindowView` without a Home pane: springs.json comes from the package, as
    /// `HomeMarkdownPolicy.install()` sets it for a pane (Springs.swift fails loudly without it, MessagesLab cdee8d9).
    init() { HomeMarkdownPolicy.installSprings() }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")
    static let id = ConversationID("conv_landing")
    static let long = "You should always restart things when turns fail, and redo the requests the failed turn dropped "
        + "without being asked: restart failed spawns and act on stuck alerts."

    struct Run { let view: MessagesWindowView; let store: Store; var vt: Double }

    private func start(width: CGFloat) -> Run {
        DisplayScale.current = 2
        Fixture.renderScale = 2
        RowCell.synchronousBitmaps = false
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let items = [TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: Self.them, parts: [.text("Started a99.")],
                                    createdAt: base, delivery: .committed, messageID: MessageID("msg_1"))]
        let summary = ConversationSummary(id: Self.id, title: "Chief", participants: people, lastSeq: 1,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(Self.id, items: items, summary: summary)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        let view = MessagesWindowView(store: store)
        var run = Run(view: view, store: store, vt: 0)
        view.clock = { [weak store] in store?.now ?? 0 }
        view.captureMode = true
        view.layer.isGeometryFlipped = true
        view.layer.speed = 0
        view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        step(&run, to: 0.05)
        return run
    }

    /// Advances the virtual clock: the engine, the layer time and the view's settle, as a display frame would.
    private func step(_ run: inout Run, to t: Double) {
        while run.vt < t {
            run.vt = min(t, run.vt + 1.0 / 120)
            run.view.layer.timeOffset = run.vt
            run.store.advance(to: run.vt)
            run.view.prepareCapture(at: run.vt)
            run.view.layoutIfNeeded()
            run.view.collection.layoutIfNeeded()
        }
    }

    /// Each flying bubble layer's resting rect in the window view (its model values: where it lands).
    private func flyingRects(_ view: MessagesWindowView) -> [CGRect] {
        func walk(_ l: CALayer) -> [CALayer] { [l] + (l.sublayers ?? []).flatMap(walk) }
        // The compose field's own overlay lives in the morph layer for good (WindowView init): not a send's.
        return (view.morphLayer.sublayers ?? []).filter { $0 !== view.compose.overlay }.flatMap(walk)
            .filter { !$0.isHidden && $0.bounds.width > 0 && $0.bounds.width < view.bounds.width }
            .map { $0.convert($0.bounds, to: view.layer) }
    }

    /// My rows: the width they were laid out for, the bubble's width and right edge, and their line count.
    private func mine(_ view: MessagesWindowView) -> [(width: CGFloat, bubble: CGFloat, right: CGFloat, lines: Int, column: CGFloat)] {
        view.model.rows.compactMap { row in
            guard case let .part(p) = row.spec.kind, p.outgoing else { return nil }
            let m = row.spec.metrics
            return (row.spec.width, p.size.width, m.rightEdge, p.text?.lines.count ?? 0, m.maxTextWidth + 2 * Fixture.bubblePadX)
        }
    }

    private func expectLanded(_ run: Run, width w: CGFloat) {
        #expect(run.view.morphs.isEmpty, "a flying bubble did not land")
        #expect(run.view.fadingMorphs.isEmpty, "a landed bubble's overlay outlived its fade")
        #expect(flyingRects(run.view).isEmpty, "an overlay layer stayed: \(flyingRects(run.view))")
        let rows = mine(run.view)
        #expect(rows.count == 1)
        for r in rows {
            #expect(r.width == w, "my row laid out for \(r.width) pt in a \(w) pt pane")
            #expect(r.bubble <= r.column + 0.5, "bubble \(r.bubble) pt wider than the column \(r.column) pt")
            #expect(r.right <= w, "bubble ends at \(r.right) pt past the \(w) pt pane")
            #expect(r.right - r.bubble >= 0, "bubble starts left of the pane")
            #expect(r.lines >= 2, "a \(Self.long.count)-character message did not wrap at \(w) pt")
        }
    }

    @Test(arguments: [480.0, 620.0, 1200.0])
    func aLongSendLandsWrappedInsideThePane(width: Double) {
        let w = CGFloat(width)
        var run = start(width: w)
        run.store.dispatch(.setDraft(Self.long))
        step(&run, to: 0.2)
        run.store.dispatch(.send)
        step(&run, to: 0.25)
        // While it flies, it flies to a place inside the pane.
        for r in flyingRects(run.view) { #expect(r.maxX <= w + 0.5, "flying layer ends at \(r.maxX) pt past \(w) pt") }
        step(&run, to: 4)
        expectLanded(run, width: w)
    }

    @Test(arguments: [480.0, 620.0, 1200.0])
    func aPaneResizedWhileTheBubbleFliesStillLandsInside(width: Double) {
        let w = CGFloat(width)
        var run = start(width: 900)
        run.store.dispatch(.setDraft(Self.long))
        step(&run, to: 0.2)
        run.store.dispatch(.send)
        step(&run, to: 0.25)
        run.view.frame.size.width = w
        step(&run, to: 4)
        expectLanded(run, width: w)
    }
}
