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
