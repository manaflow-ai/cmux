import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// A reply sent in the open thread view (the replies UI) flies to its copy in the thread view, and
/// that copy stays hidden until the flight lands (Lawrence 2026-10-21, scrawl 1792645422027: "weird
/// animation here btw, when in replies UI"). Before the fix the flying bubble went to the
/// transcript row under the blur, 120 pt below the thread's copy, while the copy already showed:
/// two bubbles for 0.7 s, then the stray one faded out in the wrong place. The thread's other
/// rows glide to their new places when the thread grows (they jumped), and under Reduce Motion
/// the thread view opens, grows and takes a send at once, with no flight.
/// Offscreen window view on a virtual clock (the HomeSendLandingTests loop).
@MainActor @Suite(.serialized) struct HomeThreadSendMotionTests {
    init() { HomeMarkdownPolicy.installSprings() }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")
    static let id = ConversationID("conv_thread_send")

    struct Run { let view: MessagesWindowView; let store: Store; var vt: Double }

    private func start() -> Run {
        DisplayScale.current = 2
        Fixture.renderScale = 2
        RowCell.synchronousBitmaps = false
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let items = (1...6).map { n in
            TranscriptItem(key: IdempotencyKey("k\(n)"), seq: UInt64(n), author: n.isMultiple(of: 2) ? Self.me : Self.them,
                           parts: [.text("Message \(n): the proxied demo is up, with its design on the branch.")],
                           createdAt: base.addingTimeInterval(Double(n)), delivery: .committed, messageID: MessageID("msg_\(n)"))
        }
        let summary = ConversationSummary(id: Self.id, title: "Chief", participants: people, lastSeq: 6,
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
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 780)
        step(&run, to: 0.05)
        return run
    }

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

    /// Opens the thread of the transcript's last Chief message and sends one reply in it.
    private func openThreadAndSend(_ run: inout Run) -> String {
        let root = run.store.state.conversation.messages.last { $0.senderId != run.store.state.me }
        run.store.dispatch(.reply(PartRef(messageId: root?.id ?? "", partIndex: 0)))
        step(&run, to: 1.0)
        run.store.dispatch(.setDraft("need to test it for 2 cases"))
        step(&run, to: 1.2)
        run.store.dispatch(.send)
        step(&run, to: 1.25)
        return run.store.state.conversation.messages.last.map { "part:\($0.id):0" } ?? ""
    }

    /// The send's flying bubble layers' resting rects in the window view.
    private func flyingRects(_ view: MessagesWindowView) -> [CGRect] {
        let overlay: CALayer = view.compose.overlay
        let maxWidth: CGFloat = view.bounds.width
        var layers: [CALayer] = []
        for top in view.morphLayer.sublayers ?? [] where top !== overlay {
            layers.append(top)
            layers.append(contentsOf: top.sublayers ?? [])
        }
        var rects: [CGRect] = []
        for l in layers where !l.isHidden && l.bounds.width > 0 && l.bounds.width < maxWidth {
            rects.append(l.convert(l.bounds, to: view.layer))
        }
        return rects
    }

    /// The thread view's copy of a row, with its spec.
    private func threadCopy(_ view: MessagesWindowView, _ key: String) -> (CanvasView, RowSpec)? {
        zip(view.threadViews, view.threadSpecs).first { $0.1.key == key }
    }

    @Test func aReplySentInTheThreadViewFliesToItsThreadCopy() throws {
        MessagesLabHomeView.reduceMotionOverride = false
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        var run = start()
        let key = openThreadAndSend(&run)
        let (copy, spec) = try #require(threadCopy(run.view, key), "the sent reply has no copy in the thread view")
        guard case let .part(p) = spec.kind else { Issue.record("not a part row"); return }
        let landed = RowDraw.balloon(RowDraw.bodyRect(spec), row: p, scale: 2).offsetBy(dx: copy.frame.minX, dy: copy.frame.minY)
        let mb = try #require(run.view.morphs[key], "no flying bubble for a reply sent in the thread view")
        // The bubble lands on the thread view's copy, not on the transcript row under the blur: the flying bubble
        // layer's model position is its landing point (Morph.swift: right edge and vertical center of the target).
        let dest = mb.bubble.superlayer?.convert(mb.bubble.position, to: run.view.layer) ?? mb.bubble.position
        #expect(abs(dest.y - landed.midY) < 2, "the bubble lands at y \(dest.y), its thread copy's center is at y \(landed.midY)")
        #expect(abs(dest.x - landed.maxX) < 2, "the bubble lands at x \(dest.x), its thread copy ends at x \(landed.maxX)")
        // Only one bubble shows while it flies: the copy waits for the landing.
        #expect(copy.layer.opacity == 0, "the thread copy shows under the flying bubble (two bubbles)")
        // The thread's other rows glide up to make room (they jumped).
        var glides = 0
        for (v, s) in zip(run.view.threadViews, run.view.threadSpecs) where s.key != key {
            if v.layer.animation(forKey: "thread.fly") != nil { glides += 1 }
        }
        #expect(glides > 0, "the thread's rows jumped to their new places")
        step(&run, to: 5)
        #expect(run.view.morphs.isEmpty, "the flying bubble did not land")
        let after = try #require(threadCopy(run.view, key))
        #expect(after.0.layer.opacity == 1, "the thread copy stayed hidden after the landing")
    }

    @Test func underReduceMotionTheThreadViewOpensAndSendsAtOnce() throws {
        MessagesLabHomeView.reduceMotionOverride = true
        defer { MessagesLabHomeView.reduceMotionOverride = nil }
        var run = start()
        let root = run.store.state.conversation.messages.last { $0.senderId != run.store.state.me }
        run.store.dispatch(.reply(PartRef(messageId: root?.id ?? "", partIndex: 0)))
        step(&run, to: 0.06)
        #expect(!run.view.threadViews.isEmpty)
        for v in run.view.threadViews {
            #expect(v.layer.animation(forKey: "thread.fly") == nil && v.layer.animation(forKey: "thread.fade") == nil,
                    "a thread row animates its open under Reduce Motion")
        }
        step(&run, to: 1.0)
        run.store.dispatch(.setDraft("need to test it for 2 cases"))
        step(&run, to: 1.2)
        run.store.dispatch(.send)
        step(&run, to: 1.21)
        let key = run.store.state.conversation.messages.last.map { "part:\($0.id):0" } ?? ""
        #expect(run.view.morphs.isEmpty, "a reply flies under Reduce Motion")
        #expect(flyingRects(run.view).isEmpty)
        let copy = try #require(threadCopy(run.view, key))
        #expect(copy.0.layer.opacity == 1, "the sent reply waits for a flight that does not run")
        for v in run.view.threadViews { #expect(v.layer.animation(forKey: "thread.fly") == nil) }
    }
}
