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

    struct RowView: View {
        let row: Row
        var body: some View {
            Text("Row \(row.id)").frame(maxWidth: .infinity, minHeight: row.height, maxHeight: row.height, alignment: .leading)
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
        var rows: [Row]
        var list: UICollectionView { controller.collectionView }

        init(rows: [Row] = (0 ..< 200).map { Row(id: $0) }) {
            self.rows = rows
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            let root = UIViewController()
            window.rootViewController = root
            holder = UIView(frame: CGRect(x: 0, y: 200, width: 402, height: 420))
            root.view.addSubview(holder)
            controller = PagedListController(direction: .down, row: { RowView(row: $0) }, edgeView: { _, _ in AnyView(EmptyView()) })
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

        func apply(_ change: (inout [Row]) -> Void) {
            change(&rows)
            controller.update(items: rows, edge: .end)
            settle()
        }

        func scroll(toTopOf item: Int, plus extra: CGFloat = 0) {
            let y = (list.layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame.minY ?? 0) + extra
            list.setContentOffset(CGPoint(x: 0, y: y - list.adjustedContentInset.top), animated: false)
            scrolled()
        }

        /// A scroll set by code ends as one in the app does (``PagedListController/scrollEndedByCode()``):
        /// the list decides whether it still follows its newest row and takes the reader's place.
        /// Before it, a list the fixture scrolled mid-list still followed its newest row, so no
        /// change kept the reader (step 1a53607a: removeFirst(10) moved the offset 0).
        func scrolled() {
            list.layoutIfNeeded()
            controller.scrollEndedByCode()
            settle()
        }

        func top(of item: Int) -> CGFloat? {
            guard let attributes = list.layoutAttributesForItem(at: IndexPath(item: item, section: 0)) else { return nil }
            return list.convert(attributes.frame.origin, to: nil).y
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

    // MARK: Leaving the newest end without a finger

    /// VoiceOver's three-finger page scroll moves the list with no finger and no fling, so the
    /// person's-move test that decides following never ran: a `.down` list scrolled a page away
    /// from its newest row still followed it, and the next row to arrive took the reader back to
    /// the top. A scroll that ends away from the newest end leaves it, however it was made.
    @Test func aVoiceOverPageScrollAwayFromTheNewestEndStopsFollowing() throws {
        let host = Host()
        defer { host.close() }
        try #require(host.controller.followsNewest, "a new list follows its newest row")
        let start = host.list.contentOffset.y
        var moved = false
        for direction in [UIAccessibilityScrollDirection.up, .down, .next] where !moved {
            _ = host.list.accessibilityScroll(direction)
            // Long enough for an animated page scroll to finish.
            for _ in 0 ..< 30 { host.turn() }
            moved = host.list.contentOffset.y - start > 200
        }
        try #require(moved, "the page scroll moved the list \(host.list.contentOffset.y - start) pt")
        #expect(!host.controller.followsNewest, "a page away from the newest end, the list still follows it")
        // The newest end gets rows: the reader stays on what they read.
        let reading = try #require(host.list.indexPathsForVisibleItems.map(\.item).sorted().dropFirst().first)
        let id = host.rows[reading].id
        let before = try #require(host.top(of: reading))
        host.apply { $0.insert(contentsOf: (0 ..< 3).map { Row(id: 50_000 + $0) }, at: 0) }
        let now = try #require(host.item(of: id))
        #expect(now == reading + 3, "the arrivals did not land above the reader")
        let after = try #require(host.top(of: now))
        #expect(abs(after - before) <= 0.5, "rows arriving at the newest end moved the reader \(after - before) pt")
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
