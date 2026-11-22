#if os(iOS) && DEBUG
@testable import CmuxMobileDesign
import SwiftUI
import Testing
import UIKit

/// The anchor, restore and frame-shift probe cases driven on ``PagedListController`` itself: each
/// change goes through its `update(items:edge:)` and the test lays the list out, with no SwiftUI host
/// in between (a hosted `@Observable` change never reached the list in the unit host: steps
/// 945d0ed8 and ec0ece73, row 10 measured 60 pt after asking for 82). Every case first asserts that
/// its change landed (the list's row count, or the row's height) before it judges any move.
/// ``PagedListCommitShiftTests`` keeps the hosted cases that prove the SwiftUI wiring reaches it.
@MainActor
@Suite(.serialized) struct PagedListAnchorDirectTests {
    struct Row: Identifiable, Equatable {
        let id: Int
        var height: CGFloat = 60
    }

    /// Height a row takes on by itself, outside any update of the list (a row whose content changes
    /// with state the item does not carry, as a Chief's typing bubble): the cell sizes itself again
    /// with no update, no reconfigure.
    @Observable final class Live {
        var extra: [Int: CGFloat] = [:]
    }

    struct RowView: View {
        let row: Row
        let live: Live
        var body: some View {
            let height = row.height + (live.extra[row.id] ?? 0)
            Text("Row \(row.id)").frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        }
    }

    final class Seen {
        var shifts: [CGFloat] = []
        var drawn: [CGFloat] = []
        var worst: CGFloat { shifts.map(abs).max() ?? 0 }
        var drawnWorst: CGFloat { drawn.map(abs).max() ?? 0 }
        func clear() { shifts = []; drawn = [] }
    }

    /// The list in a key window, in a plain holder clear of the safe areas (a transform on the holder
    /// moves the list on screen with no layout pass and no inset change). Main actor like the suite:
    /// a nested type does not take its enclosing type's isolation.
    @MainActor final class Host {
        let window: UIWindow
        let holder: UIView
        let controller: PagedListController<Row, RowView>
        let seen = Seen()
        let live = Live()
        var rows: [Row]
        var list: UICollectionView { controller.collectionView }

        init(rows: [Row] = (0 ..< 200).map { Row(id: $0) }, direction: PagedListDirection = .down, animatesNewest: Bool = false,
             cachesHeights: Bool = true) {
            self.rows = rows
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            let root = UIViewController()
            window.rootViewController = root
            holder = UIView(frame: CGRect(x: 0, y: 200, width: 402, height: 420))
            root.view.addSubview(holder)
            let live = live
            controller = PagedListController(direction: direction, row: { RowView(row: $0, live: live) }, edgeView: { _, _ in AnyView(EmptyView()) })
            controller.animatesNewest = animatesNewest
            controller.cachesHeights = cachesHeights
            let probe = PagedListProbe()
            let seen = seen
            probe.frameShift = { seen.shifts.append($0) }
            probe.drawnShift = { shift, _ in seen.drawn.append(shift) }
            controller.probe = probe
            controller.collectionView.frame = holder.bounds
            holder.addSubview(controller.collectionView)
            window.makeKeyAndVisible()
            controller.update(items: rows, edge: .end)
            settle()
        }

        func apply(_ change: (inout [Row]) -> Void, settling: Bool = true) {
            change(&rows)
            controller.update(items: rows, edge: .end)
            if settling { settle() } else { turn() }
        }

        /// One frame: lay out, commit, and let the run loop turn once (the probe samples it).
        func turn() {
            list.layoutIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
        }

        /// To the newest row of an `.up` list (its bottom), where the list follows new rows.
        func scrollToNewest() {
            list.layoutIfNeeded()
            let bottom = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
            list.setContentOffset(CGPoint(x: 0, y: max(-list.adjustedContentInset.top, bottom)), animated: false)
            settle()
        }

        func scroll(toTopOf item: Int, plus extra: CGFloat = 0) {
            let y = (list.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame.minY ?? 0) + extra
            list.setContentOffset(CGPoint(x: 0, y: y - list.adjustedContentInset.top), animated: false)
            settle()
        }

        func top(of item: Int) -> CGFloat? {
            guard let attributes = list.layoutAttributesForItem(at: IndexPath(item: item, section: 0)) else { return nil }
            return list.convert(attributes.frame.origin, to: nil).y
        }

        /// How far the list is from its newest end (the bottom of an `.up` list).
        var distanceToNewest: CGFloat {
            list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height - list.contentOffset.y
        }

        /// The item index of the row with `id` now.
        func item(of id: Int) -> Int? { rows.firstIndex { $0.id == id } }

        func height(of item: Int) -> CGFloat {
            list.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame.height ?? -1
        }

        /// Lays the list out and commits the frame, then lets the run loop turn so the probe's
        /// committed-frame observer samples it.
        func settle() {
            for _ in 0 ..< 6 {
                list.layoutIfNeeded()
                CATransaction.flush()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        func close() { window.isHidden = true }
    }

    // MARK: The anchor

    /// The row cut by the list's top edge grows: the rows below it, all the reader sees, stay put.
    @Test func aRowCutByTheTopEdgeGrowingKeepsTheRowsBelowStill() throws {
        let host = Host()
        defer { host.close() }
        host.scroll(toTopOf: 10, plus: 20)
        let before = try #require(host.top(of: 11))
        host.apply { $0[10].height = 82 }
        #expect(abs(host.height(of: 10) - 82) < 0.5, "row 10 measured \(host.height(of: 10)) pt: the grow did not land")
        let after = try #require(host.top(of: 11))
        #expect(abs(after - before) <= 0.5, "the row under the cut row moved \(after - before) pt")
    }

    /// The cut row is the only row on screen: nothing below it is in view, so it keeps its own top.
    @Test func aRowAloneOnScreenCutByTheTopEdgeKeepsItsTopWhenItGrows() throws {
        var rows = (0 ..< 200).map { Row(id: $0) }
        rows[10].height = 1200
        let host = Host(rows: rows)
        defer { host.close() }
        host.scroll(toTopOf: 10)
        #expect(abs(host.height(of: 10) - 1200) < 0.5, "row 10 measured \(host.height(of: 10)) pt")
        host.scroll(toTopOf: 10, plus: 100)
        let visible = host.list.indexPathsForVisibleItems.map(\.item)
        #expect(visible == [10], "row 10 alone on screen, saw \(visible)")
        let before = try #require(host.top(of: 10))
        host.apply { $0[10].height = 1300 }
        #expect(abs(host.height(of: 10) - 1300) < 0.5, "row 10 measured \(host.height(of: 10)) pt: the grow did not land")
        let after = try #require(host.top(of: 10))
        #expect(abs(after - before) <= 0.5, "the row alone on screen moved \(after - before) pt")
    }

    // MARK: The follow path (the open defect)

    /// An `.up` list following its newest row: rows arrive at the newest end every frame, so the
    /// follow spring keeps sliding, while rows above the reader go and others change height, as the
    /// flood load does. Every committed frame is sampled; nothing may draw off the slide (the 22 pt
    /// one-frame flash of up-slow/medium/fast-flood and up-fast-busy, steps 3c24c106 and e83632fe:
    /// `follows=true spring=1`, an update's `U-118` and the restore's `r+170` in one frame).
    @Test func followingTheNewestRowsWhileRowsAboveGoOrResizeDrawsNoShift() throws {
        let host = Host(direction: .up, animatesNewest: true)
        defer { host.close() }
        host.scrollToNewest()
        host.seen.clear()
        let count = host.list.numberOfItems(inSection: 0)
        var arrived = 0
        var removed = 0
        for step in 0 ..< 24 {
            let visible = host.list.indexPathsForVisibleItems.map(\.item).sorted()
            let above = visible.count > 3 ? host.rows[visible[visible.count / 3]].id : nil
            let resized = visible.count > 4 ? visible[1] : nil
            host.apply({ rows in
                rows.append(Row(id: 10_000 + step))
                if step % 2 == 0, let above { rows.removeAll { $0.id == above } }
                if step % 3 == 0, let resized, resized < rows.count { rows[resized].height = rows[resized].height == 60 ? 104 : 60 }
            }, settling: false)
            arrived += 1
            if step % 2 == 0, above != nil { removed += 1 }
        }
        host.settle()
        #expect(host.list.numberOfItems(inSection: 0) == count + arrived - removed,
                "the changes did not land: \(host.list.numberOfItems(inSection: 0)) rows, expected \(count + arrived - removed)")
        #expect(!host.seen.drawn.isEmpty, "the drawn measure took no sample")
        #expect(host.seen.worst <= 0.5, "frame shift while following: \(host.seen.shifts.filter { abs($0) > 0.5 })")
        #expect(host.seen.drawnWorst <= 0.5, "drawn shift while following: \(host.seen.drawn.filter { abs($0) > 0.5 })")
    }

    /// The same follow, with every arriving row far taller than the list's estimate, so each comes
    /// in at the estimated height and self-sizes on its way into view while the spring slides (a
    /// restore correcting for a size change the slide already absorbed: `U-118` then `r+170`).
    @Test func followingTheNewestRowsAsTallArrivalsSizeThemselvesDrawsNoShift() throws {
        let host = Host(direction: .up, animatesNewest: true)
        defer { host.close() }
        host.scrollToNewest()
        host.seen.clear()
        let count = host.list.numberOfItems(inSection: 0)
        var removed = 0
        for step in 0 ..< 24 {
            let visible = host.list.indexPathsForVisibleItems.map(\.item).sorted()
            let above = visible.count > 3 ? host.rows[visible[visible.count / 3]].id : nil
            host.apply({ rows in
                rows.append(Row(id: 20_000 + step, height: step % 2 == 0 ? 170 : 118))
                if step % 3 == 0, let above { rows.removeAll { $0.id == above } }
            }, settling: false)
            if step % 3 == 0, above != nil { removed += 1 }
        }
        host.settle()
        #expect(host.list.numberOfItems(inSection: 0) == count + 24 - removed,
                "the changes did not land: \(host.list.numberOfItems(inSection: 0)) rows, expected \(count + 24 - removed)")
        let last = host.list.numberOfItems(inSection: 0) - 1
        #expect(abs(host.height(of: last) - 118) < 0.5, "the newest row measured \(host.height(of: last)) pt, not 118")
        #expect(!host.seen.drawn.isEmpty, "the drawn measure took no sample")
        #expect(host.seen.worst <= 0.5, "frame shift while following tall arrivals: \(host.seen.shifts.filter { abs($0) > 0.5 })")
        #expect(host.seen.drawnWorst <= 0.5, "drawn shift while following tall arrivals: \(host.seen.drawn.filter { abs($0) > 0.5 })")
    }

    /// The follow spring alone: rows arrive below the newest row and the list slides to them, with
    /// nothing on screen changing. The slide is the list's own move, explained frame by frame, so
    /// neither measure may read anything (the drawn measure reads presentation layers: a slide it
    /// saw lagging the offset would read here).
    @Test func theFollowSlideAloneDrawsNoShift() throws {
        let host = Host(direction: .up, animatesNewest: true)
        defer { host.close() }
        host.scrollToNewest()
        host.seen.clear()
        let start = host.list.contentOffset.y
        let count = host.list.numberOfItems(inSection: 0)
        for step in 0 ..< 12 {
            host.apply({ $0.append(Row(id: 30_000 + step)) }, settling: false)
            host.turn()
        }
        host.settle()
        #expect(host.list.numberOfItems(inSection: 0) == count + 12, "the arrivals did not land")
        #expect(host.list.contentOffset.y - start > 600, "the list did not slide to its new rows: moved \(host.list.contentOffset.y - start) pt")
        #expect(!host.seen.drawn.isEmpty, "the drawn measure took no sample")
        #expect(host.seen.worst <= 0.5, "frame shift on a plain slide: \(host.seen.shifts.filter { abs($0) > 0.5 })")
        #expect(host.seen.drawnWorst <= 0.5, "drawn shift on a plain slide: \(host.seen.drawn.filter { abs($0) > 0.5 })")
    }

    /// The follow-path flash (cheap-probe rep 5baccd69, frame #97: `o+78` then `m_+22`, the newest
    /// row drawn 22 pt off the slide): while the spring slides an `.up` list to rows arriving below,
    /// a row on screen above the newest one sizes itself again with no update (its content changed
    /// with state the item does not carry). Only rows above the reader's top edge were corrected, and
    /// the list keeps its newest row on the bottom edge only once the slide ends, so for that frame
    /// every row under the grown one drew lower. Rows on screen keep the newest row's bottom still,
    /// as Messages does: a row that grows pushes the rows above it up.
    @Test func aRowOnScreenSizingItselfWhileTheListSlidesKeepsTheNewestRowStill() throws {
        let host = Host(direction: .up, animatesNewest: true, cachesHeights: false)
        defer { host.close() }
        host.scrollToNewest()
        host.seen.clear()
        var grown: [(id: Int, to: CGFloat)] = []
        var midSlide = 0
        for step in 0 ..< 12 {
            host.apply({ $0.append(Row(id: 40_000 + step)) }, settling: false)
            host.turn()
            // A row in the middle of the screen, above the newest row: it grows (or shrinks back)
            // between updates, mid-slide.
            let visible = host.list.indexPathsForVisibleItems.map(\.item).sorted()
            guard visible.count > 4 else { continue }
            let id = host.rows[visible[visible.count / 2]].id
            let extra: CGFloat = (host.live.extra[id] ?? 0) == 0 ? 22 : 0
            if host.distanceToNewest > 1 { midSlide += 1 }
            host.live.extra[id] = extra
            grown.append((id, 60 + extra))
            host.turn()
        }
        host.settle()
        #expect(grown.count >= 8, "only \(grown.count) rows were resized")
        #expect(midSlide >= 4, "only \(midSlide) of the resizes came while the list was sliding")
        // The resize landed: the last row resized measures what it was given.
        if let last = grown.last, let item = host.item(of: last.id) {
            #expect(abs(host.height(of: item) - last.to) < 0.5, "row \(last.id) measured \(host.height(of: item)) pt, not \(last.to): the resize did not land")
        }
        #expect(host.seen.worst <= 0.5, "frame shift while a row resized mid-slide: \(host.seen.shifts.filter { abs($0) > 0.5 })")
        #expect(host.seen.drawnWorst <= 0.5, "drawn shift while a row resized mid-slide: \(host.seen.drawn.filter { abs($0) > 0.5 })")
    }

    /// keepLine's scope: an `.up` list the reader left (mid-list, not following its newest row) keeps
    /// the reader's row, not the bottom edge. A row on screen below the reader that sizes itself
    /// pushes only the rows under it; the row being read stays where it is.
    @Test func anUpListNotFollowingKeepsTheReaderWhenARowBelowResizes() throws {
        let host = Host(direction: .up, animatesNewest: true, cachesHeights: false)
        defer { host.close() }
        // The status bar's scroll to top: the list stops following its newest row (no finger needed).
        host.controller.scrollViewDidScrollToTop(host.list)
        host.scroll(toTopOf: 100)
        try #require(!host.controller.followsNewest, "the list still follows its newest row")
        host.seen.clear()
        let visible = host.list.indexPathsForVisibleItems.map(\.item).sorted()
        try #require(visible.count > 4 && visible.contains(100), "visible rows \(visible)")
        let below = visible[visible.count / 2]
        try #require(below > 100, "the middle row \(below) is not below the reader")
        let before = try #require(host.top(of: 100))
        let underBefore = try #require(host.top(of: below + 1))
        host.live.extra[host.rows[below].id] = 22
        host.settle()
        #expect(abs(host.height(of: below) - 82) < 0.5, "row \(below) measured \(host.height(of: below)) pt: the resize did not land")
        let after = try #require(host.top(of: 100))
        #expect(abs(after - before) <= 0.5, "the row being read moved \(after - before) pt")
        let underAfter = try #require(host.top(of: below + 1))
        #expect(abs(underAfter - underBefore - 22) <= 0.5, "the row under the resized one moved \(underAfter - underBefore) pt, not 22")
        #expect(host.seen.worst <= 0.5, "frame shift: \(host.seen.shifts.filter { abs($0) > 0.5 })")
    }

    // MARK: The frame-shift probe

    /// A row inserted next to the reader in the frame everything moves 10 pt: the move counts in full
    /// (the measure follows the row by its id; a change around it does not drop the frame).
    @Test func aMoveInTheFrameARowArrivesNextToTheReaderCountsInFull() throws {
        let host = Host()
        defer { host.close() }
        host.scroll(toTopOf: 10)
        host.seen.clear()
        let count = host.list.numberOfItems(inSection: 0)
        host.holder.transform = CGAffineTransform(translationX: 0, y: 10)
        host.apply { $0.insert(Row(id: 1000), at: 11) }
        #expect(host.list.numberOfItems(inSection: 0) == count + 1, "the insert did not land")
        let big = host.seen.shifts.filter { abs($0) > 0.5 }
        #expect(big.count == 1 && abs(abs(big[0]) - 10) < 0.5, "a 10 pt move with a row arriving next to the reader measured \(host.seen.shifts)")
    }

    /// (a) A move drawn with no offset change counts in full on the drawn measure.
    @Test func aDrawnMoveWithNoOffsetChangeCountsInFull() throws {
        let host = Host()
        defer { host.close() }
        host.seen.clear()
        let offset = host.list.contentOffset
        host.holder.transform = CGAffineTransform(translationX: 0, y: 10)
        host.settle()
        #expect(host.list.contentOffset == offset)
        #expect(!host.seen.drawn.isEmpty, "the drawn measure took no sample")
        #expect(abs(host.seen.drawnWorst - 10) < 0.5, "a drawn 10 pt move measured \(host.seen.drawn)")
    }

    /// (b) Rows removed above the reader: the offset and the layout move together by the removed
    /// height and nothing on screen moves.
    @Test func theOffsetAndTheLayoutMovingTogetherDrawNoShift() throws {
        let host = Host()
        defer { host.close() }
        host.scroll(toTopOf: 20)
        host.seen.clear()
        let count = host.list.numberOfItems(inSection: 0)
        let offset = host.list.contentOffset.y
        host.apply { $0.removeFirst(10) }
        #expect(host.list.numberOfItems(inSection: 0) == count - 10, "the removal did not land")
        #expect(abs(host.list.contentOffset.y - (offset - 600)) < 0.5, "the offset moved \(host.list.contentOffset.y - offset) pt")
        #expect(!host.seen.drawn.isEmpty, "the drawn measure took no sample")
        #expect(host.seen.drawnWorst <= 0.5, "a removal of the rows above measured \(host.seen.drawn)")
    }

    /// (c) The row being read is removed: the measure follows a row drawn in both frames, and the
    /// anchor keeps the next row where it was.
    @Test func theRowBeingReadSwappedOutFollowsASurvivingRow() throws {
        let host = Host()
        defer { host.close() }
        host.scroll(toTopOf: 20)
        host.seen.clear()
        let count = host.list.numberOfItems(inSection: 0)
        host.apply { $0.removeAll { $0.id == 20 } }
        #expect(host.list.numberOfItems(inSection: 0) == count - 1, "the removal did not land")
        #expect(!host.seen.drawn.isEmpty, "the drawn measure took no sample")
        #expect(host.seen.drawnWorst <= 0.5, "the removed row was not followed by a surviving one: \(host.seen.drawn)")
    }
}
#endif
