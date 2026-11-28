// Copied by scripts/cmux-next/home-messageslab-harness.sh (compare) into the
// gitignored Tests/MessagesLabHomeTests/Upstream next to MessagesLab's
// FlashCheck.swift; not compiled otherwise (it needs FlashCheck).
import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// MessagesLab's `--coverage-check` script (FlashCheck.runCoverage) on the
/// Home path: the sends go through the adapter (`.send` at the press, the
/// alias, then HomeStore's pending item and echo as snapshots), and every
/// 120 Hz frame is checked with MessagesLab's own `coverageGaps` and
/// `unfilledOutgoing` on presented values. `HOME_COVERAGE_OUT` keeps the
/// result as JSON in FlashCheck's format.
@MainActor @Suite(.serialized) struct HomeCoverageCheck {
    typealias H = HomeHarnessTests

    @Test func aSendWhileScrolledUpLeavesNoGapAndKeepsEveryFillOnTheHomePath() throws {
        DisplayScale.current = 2
        Fixture.renderScale = 2
        DisplayScale.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        RowCell.synchronousBitmaps = false
        RowBitmaps.shared.removeAll()
        var items: [TranscriptItem] = []
        for i in 1...80 {
            let author: ParticipantID = i % 3 == 0 ? H.me : H.them
            let text = i % 4 == 0 ? "A longer message number \(i) that wraps onto a second line in the bubble." : "Message \(i)"
            items.append(H.item(Seq(i), author, text, at: -Double(81 - i) * 50))
        }
        var sum = H.summary(lastSeq: 80)
        var core = ProjectionCore(me: H.me)
        let (conv, w) = core.install(H.id, items: items, summary: sum)
        let store = Store(conversation: conv, baseDate: Replay.base, windowStart: w.start, total: w.total)
        store.responder = nil
        var vt = 0.0
        let view = MessagesWindowView(store: store)
        view.clock = { vt }
        view.captureMode = true
        view.layer.isGeometryFlipped = true
        view.layer.speed = 0
        var bad: [[String: Any]] = []
        var unfilled: [[String: Any]] = []
        func frame() {
            vt += 1.0 / 120
            view.layer.timeOffset = vt
            store.advance(to: vt)
            view.prepareCapture(at: vt)
            view.layoutIfNeeded()
            view.collection.layoutIfNeeded()
            let saved = Presenter.apply(view.layer)
            for g in FlashCheck.coverageGaps(view) { bad.append(["t": vt, "gapFrom": Double(g.0), "gapTo": Double(g.1)]) }
            for u in FlashCheck.unfilledOutgoing(view) { unfilled.append(["t": vt, "row": u]) }
            Presenter.restore(saved)
        }
        func frames(until t: Double) { while vt < t { frame() } }
        func push() {
            let d = core.step(items: items, summary: sum)
            precondition(!d.rebuild, "the script never rebuilds")
            d.actions.forEach(store.dispatch)
        }
        /// HomeProjection.send: `.send` at the press and the alias, then the store's pending item.
        func send(_ text: String, key: String, seq: Seq) {
            store.advance(to: vt)
            store.dispatch(.setDraft(text))
            frames(until: vt + 0.1)
            store.advance(to: vt)
            store.dispatch(.send)
            let k = IdempotencyKey(key)
            let recorded = core.recordSend(k, in: store.state)
            #expect(recorded)
            items.append(TranscriptItem(key: k, seq: nil, author: H.me, parts: [.text(text)], createdAt: H.date(vt), delivery: .sending))
            push()
        }
        frames(until: 0.5)
        let cv = view.collection
        cv.contentOffset.y = max(view.minOffset, cv.contentOffset.y - 500)
        view.userScrolled()
        frames(until: 1.0)
        send("Sent while scrolled up", key: "cov1", seq: 81)
        frames(until: 2.0)
        // The owner's echo: Delivered.
        store.advance(to: vt)
        items[items.count - 1].seq = 81
        items[items.count - 1].delivery = .committed
        items[items.count - 1].messageID = MessageID("msg_81")
        sum = H.summary(lastSeq: 81)
        push()
        frames(until: 3.0)
        send("Sent at the bottom", key: "cov2", seq: 82)
        frames(until: 5.0)
        if let out = ProcessInfo.processInfo.environment["HOME_COVERAGE_OUT"] {
            LiveProbes.write(["gapFrames": bad.count, "gaps": Array(bad.prefix(50)), "unfilledRowFrames": unfilled.count,
                              "unfilled": Array(unfilled.prefix(50))], out)
        }
        #expect(bad.isEmpty, "frames with a gap in the transcript: \(bad.prefix(5))")
        #expect(unfilled.isEmpty, "outgoing bubble-frames without their fill: \(unfilled.prefix(5))")
    }
}
