import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Lawrence, 2026-11-07 (a screenshot of a reply thread open over the blurred transcript): "clicking some parts of
/// empty space still doesn't get out of this view". A click anywhere off the thread's bubbles, links and the message
/// box closes the thread: the space beside a bubble in its row, the date and "Read" lines, the blurred backdrop
/// (also where the opener's row lies under the blur, away from its "N Replies"). A click on a bubble or on the
/// message box keeps it open. The real view over a real `HomeStore` (`HomeChatRig`); clicks go through the pane's
/// click path (`ChatController.clicked`).
@MainActor @Suite(.serialized) struct HomeThreadEmptySpaceTests {
    /// The root (mine) with three Chief replies in its thread.
    private func threadRig() async throws -> HomeChatRig {
        let r = try await HomeChatRig(history: 6)
        let rootText = "\(HomeChatRig.tag) maybe we should have windowed chief instead, where chief floats in the window"
        await r.send(rootText)
        await HomeChatRig.until { [store = r.store] in
            store.transcript(for: HomeChatRig.conversation).contains { $0.plainText == rootText && $0.messageID != nil }
        }
        let root = try #require(r.store.transcript(for: HomeChatRig.conversation).first { $0.plainText == rootText }?.messageID)
        for n in 1...3 {
            #expect(await r.post([.text("\(HomeChatRig.tag) floating Chief reply \(n)")], key: IdempotencyKey("empty-reply-\(n)"), threadRoot: root))
        }
        for _ in 0..<4 { r.frame() }
        return r
    }

    /// The thread opener ("N Replies" or the preview): its point, and the band of its row that opens the thread.
    private func opener(_ demo: MessagesWindowView) throws -> (point: CGPoint, band: CGRect) {
        let cells = demo.collection.visibleCells.compactMap { $0 as? RowCell }
            .map { $0.convert($0.bounds, to: demo) }.sorted { $0.maxY > $1.maxY }
        for r in cells {
            for y in stride(from: r.maxY, to: r.minY, by: -3) {
                let xs = stride(from: r.minX, to: r.maxX, by: 2).filter { demo.repliesHit(CGPoint(x: $0, y: y)) != nil }
                if let lo = xs.first, let hi = xs.last {
                    return (CGPoint(x: lo, y: y), CGRect(x: lo - 2, y: r.minY, width: hi - lo + 4, height: r.height))
                }
            }
        }
        Issue.record("no thread preview or N Replies in the transcript")
        throw CancellationError()
    }

    private func open(_ r: HomeChatRig, at p: CGPoint) throws {
        if r.view.debugOpenThread == nil { r.view.controller.clicked(p) }
        for _ in 0..<4 { r.frame() }
        try #require(r.view.debugOpenThread != nil, "the opener did not open the thread")
    }

    /// Empty spots of the open thread view: beside each bubble in its row (the side away from it), each line that is
    /// no bubble (the date, "Read"), and the backdrop above and below the rows. None on a bubble, the message box,
    /// or the opener's own band.
    private func emptySpots(_ demo: MessagesWindowView, opener: CGRect) -> [(String, CGPoint)] {
        var spots: [(String, CGPoint)] = []
        let field = demo.compose.fieldRect.insetBy(dx: -60, dy: -8)
        for (v, spec) in zip(demo.threadViews, demo.threadSpecs) {
            let row = v.frame
            switch spec.kind {
            case let .part(part):
                let body = RowDraw.bodyRect(spec).offsetBy(dx: row.minX, dy: row.minY)
                let x = part.outgoing ? max(row.minX + 16, body.minX - 40) : min(row.maxX - 16, body.maxX + 40)
                spots.append(("beside \(part.outgoing ? "my" : "a Chief") bubble", CGPoint(x: x, y: body.midY)))
            case .separator, .receipt:
                spots.append(("a date or Read line", CGPoint(x: row.minX + 16, y: row.midY)))
            default: break
            }
        }
        let area = demo.threadArea
        if let top = demo.threadViews.map(\.frame.minY).min(), let bottom = demo.threadViews.map(\.frame.maxY).max() {
            spots.append(("the backdrop above the rows", CGPoint(x: area.midX, y: max(area.minY + 6, top - 30))))
            spots.append(("the backdrop below the rows", CGPoint(x: area.maxX - 16, y: min(area.maxY - 6, bottom + 30))))
        }
        return spots.filter { _, p in
            demo.hit(p) == nil && !field.contains(p) && !opener.contains(p) && demo.bounds.contains(p)
        }
    }

    @Test func aClickOnAnyEmptySpotClosesTheThread() async throws {
        let r = try await threadRig()
        defer { r.stop() }
        let demo = try #require(r.view.controller.demo)
        let (p, band) = try opener(demo)
        try open(r, at: p)
        let spots = emptySpots(demo, opener: band)
        #expect(spots.count >= 5, "too few empty spots found: \(spots.map(\.0))")
        for (name, spot) in spots {
            try open(r, at: p)
            r.view.controller.clicked(spot)
            for _ in 0..<4 { r.frame() }
            #expect(r.view.debugOpenThread == nil, "a click \(name) at \(spot) did not close the thread")
        }
    }

    /// Lawrence, 2026-11-18 (a screen recording of a Chief thread with nested replies): "clicking some space fails to
    /// close it". In the open thread, a reply that has replies of its own carries a "1 Reply" line under it, and a click
    /// anywhere across the pane's width at that line's height took the line's drill-in (the view stayed open) instead of
    /// the outside-click close. Only the "N Replies" words open the branch; the rest of that line is empty space.
    @Test func aClickBesideANestedRepliesLineClosesTheThread() async throws {
        let r = try await threadRig()
        defer { r.stop() }
        let replies = r.store.transcript(for: HomeChatRig.conversation).filter { $0.plainText.contains("floating Chief reply") }
        let parent = try #require(replies.dropFirst().first?.messageID, "the second Chief reply")
        let root = try #require(replies.first?.threadRoot)
        #expect(await r.post([.text("\(HomeChatRig.tag) nested answer")], key: IdempotencyKey("empty-nested-1"), threadRoot: root, parent: parent))
        for _ in 0..<4 { r.frame() }
        let demo = try #require(r.view.controller.demo)
        let (p, band) = try opener(demo)
        try open(r, at: p)
        let field = demo.compose.fieldRect.insetBy(dx: -60, dy: -8)
        var spots: [(String, CGPoint)] = []
        var labels: [CGPoint] = []
        for (v, spec) in zip(demo.threadViews, demo.threadSpecs) {
            guard case let .replies(_, _, outgoing) = spec.kind else { continue }
            let y = v.frame.minY + RowDraw.margin + spec.height / 2
            // The words sit at the line's start on the bubble's side ("1 Reply" is about 40 pt wide).
            labels.append(CGPoint(x: outgoing ? v.frame.minX + spec.metrics.receiptRight - 12 : v.frame.minX + Fixture.labelLeft + spec.cmuxIndent + 12, y: y))
            for x in [v.frame.midX, outgoing ? v.frame.minX + 16 : v.frame.maxX - 16] {
                spots.append(("on the \(outgoing ? "my" : "a Chief") reply's \"1 Reply\" line, away from its words", CGPoint(x: x, y: y)))
            }
        }
        try #require(!labels.isEmpty, "no \"N Replies\" line in the open thread view")
        spots = spots.filter { _, q in demo.hit(q) == nil && !field.contains(q) && !band.contains(q) && demo.bounds.contains(q) }
        #expect(spots.count >= 2, "too few empty spots on the line: \(spots.map(\.0))")
        for (name, spot) in spots {
            try open(r, at: p)
            let path = r.view.debugOpenThreadPath
            r.view.controller.clicked(spot)
            for _ in 0..<4 { r.frame() }
            #expect(r.view.debugOpenThread == nil, "a click \(name) at \(spot) did not close the thread (path \(path) -> \(r.view.debugOpenThreadPath))")
        }
        // The words themselves still open the reply's branch (the view stays open).
        try open(r, at: p)
        r.view.controller.clicked(labels[0])
        for _ in 0..<4 { r.frame() }
        #expect(r.view.debugOpenThread != nil, "a click on the \"1 Reply\" words closed the thread")
        #expect(r.view.debugOpenThreadPath.count >= 2, "a click on the \"1 Reply\" words did not open the branch")
    }

    @Test func aClickOnABubbleOrTheMessageBoxKeepsTheThreadOpen() async throws {
        let r = try await threadRig()
        defer { r.stop() }
        let demo = try #require(r.view.controller.demo)
        let (p, _) = try opener(demo)
        try open(r, at: p)
        let root = r.view.debugOpenThread
        var kept: [(String, CGPoint)] = []
        for (v, spec) in zip(demo.threadViews, demo.threadSpecs) {
            guard case .part = spec.kind else { continue }
            let body = RowDraw.bodyRect(spec).offsetBy(dx: v.frame.minX, dy: v.frame.minY)
            kept.append(("on a bubble", CGPoint(x: body.midX, y: body.midY)))
        }
        kept.append(("on the message box", CGPoint(x: demo.compose.fieldRect.midX, y: demo.compose.fieldRect.midY)))
        #expect(kept.count >= 4)
        for (name, spot) in kept {
            r.view.controller.clicked(spot)
            for _ in 0..<4 { r.frame() }
            #expect(r.view.debugOpenThread == root, "a click \(name) closed the thread")
        }
    }
}
