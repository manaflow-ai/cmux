#if os(iOS)
@testable import CmuxMobileFeed
import Foundation
import SwiftUI
import Testing
import UIKit

/// The Feed list does work for the rows on screen and a bounded overscan, never for the whole
/// list: at 1,000 and 10,000 events the table asks the same few heights, lays out the same few
/// rows, a one-event change reconfigures that row alone, and a width change lays out only the
/// rows on screen (the rest when they scroll in). With exact heights for every row
/// (`estimatedRowHeight = 0`) the table asked all N heights on every load and height change, and
/// a width change laid out and reconfigured all N rows.
@MainActor @Suite(.serialized) struct FeedVisibleRowsTests {
    /// Budgets for one load or one event, flat in N. A phone screen shows about ten rows; UIKit
    /// asks a row's height more than once per pass and prefetches about a screen ahead.
    static let heightBudget = 200
    static let layoutBudget = 80

    struct Counts: CustomStringConvertible {
        var heights = 0, laidOut = 0, reconfigured = 0, configured = 0
        var description: String { "heights=\(heights) laidOut=\(laidOut) reconfigured=\(reconfigured) configured=\(configured)" }

        static func - (a: Counts, b: Counts) -> Counts {
            Counts(heights: a.heights - b.heights, laidOut: a.laidOut - b.laidOut,
                   reconfigured: a.reconfigured - b.reconfigured, configured: a.configured - b.configured)
        }
    }

    struct Run {
        var load = Counts(), visibleChange = Counts(), hiddenChange = Counts(), resize = Counts()
        var topBefore: String?, topAfter: String?
        /// Visible rows whose height is not their layout's at the current width, after the rotation.
        var staleRows: [String] = []
    }

    static func item(_ index: Int, extra: Int = 0) -> FeedItem {
        // Bodies of one to four lines, so rows differ in height.
        let lines = (0 ... (index % 4) + extra).map { "Line \($0) of event \(index): the agent finished a step." }
        return FeedListPlanTests.item("e\(index)", lines.joined(separator: "\n"), ago: Double(index))
    }

    static func counts(_ list: FeedListController) -> Counts {
        Counts(heights: list.heightQueries, laidOut: list.rowsLaidOut, reconfigured: list.rowsReconfigured, configured: list.cellsConfigured)
    }

    /// Runs layout passes until the list has applied everything and shows `rows` events (bounded).
    static func settle(_ window: UIWindow, _ list: FeedListController, rows: Int) async {
        let deadline = Date().addingTimeInterval(120)
        var quiet = 0
        while Date() < deadline, quiet < 4 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
            let table = list.collectionView
            let shown = (table?.numberOfSections ?? 0) > 1 ? table?.numberOfRows(inSection: 1) ?? 0 : 0
            quiet = !list.hasPendingWork && shown == rows ? quiet + 1 : 0
        }
    }

    /// The first event row whose bottom is below the top of the visible area.
    static func topRow(_ table: UITableView) -> String? {
        let top = table.contentOffset.y + table.adjustedContentInset.top
        let rows = (table.indexPathsForVisibleRows ?? []).filter { $0.section == 1 }.sorted()
        return rows.first { table.rectForRow(at: $0).maxY > top + 0.5 }.map { "e\($0.row)" }
    }

    func run(_ n: Int) async -> Run {
        var items = (0 ..< n).map { Self.item($0) }
        let list = FeedListController(context: FeedRowContext(store: FeedStore(items: [])), swipe: FeedSwipeCoordinator(), control: FeedListControl())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = FeedCollectionController(collection: list.makeView())
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let update = { list.update(items: items, header: AnyView(EmptyView()), signature: AnyHashable(0), headerContent: AnyHashable(0)) }
        var result = Run()

        update()
        await Self.settle(window, list, rows: n)
        result.load = Self.counts(list)

        // One event on screen changes (it grows a line).
        var before = Self.counts(list)
        items[1] = Self.item(1, extra: 2)
        update()
        await Self.settle(window, list, rows: n)
        result.visibleChange = Self.counts(list) - before

        // One event far below the screen changes.
        before = Self.counts(list)
        items[n - 2] = Self.item(n - 2, extra: 2)
        update()
        await Self.settle(window, list, rows: n)
        result.hiddenChange = Self.counts(list) - before

        // A rotation: the row at the top stays at the top.
        list.scrollTo(id: "e20", animated: false)
        await Self.settle(window, list, rows: n)
        result.topBefore = list.collectionView.flatMap { Self.topRow($0) }
        before = Self.counts(list)
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        await Self.settle(window, list, rows: n)
        result.resize = Self.counts(list) - before
        result.topAfter = list.collectionView.flatMap { Self.topRow($0) }
        // Rows laid out at the old width (before the rotation) and rows never laid out scroll in at
        // their height for the new width.
        for id in ["e24", "e8", "e60"] {
            list.scrollTo(id: id, animated: false)
            await Self.settle(window, list, rows: n)
            result.staleRows += Self.staleRows(list)
        }
        return result
    }

    static func staleRows(_ list: FeedListController) -> [String] {
        guard let table = list.collectionView else { return ["no table"] }
        let width = Int(table.bounds.width.rounded())
        return (table.indexPathsForVisibleRows ?? []).filter { $0.section == 1 }.compactMap { (indexPath: IndexPath) -> String? in
            guard let cell = table.cellForRow(at: indexPath) as? FeedRowCell, let layout = cell.layout else { return "e\(indexPath.row):no cell" }
            let height = table.rectForRow(at: indexPath).height
            guard layout.key.width != width || abs(height - layout.height) > 0.5 else { return nil }
            return "e\(indexPath.row):\(Int(height))/\(Int(layout.height))@\(layout.key.width)"
        }
    }

    static func flat(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= max(3, max(a, b) / 10) }

    @Test func workIsForTheRowsOnScreenAtAnyLength() async {
        let small = await run(1_000)
        let large = await run(10_000)
        print("FEED-COUNTS n=1000 load{\(small.load)} visibleChange{\(small.visibleChange)} hiddenChange{\(small.hiddenChange)} resize{\(small.resize)}")
        print("FEED-COUNTS n=10000 load{\(large.load)} visibleChange{\(large.visibleChange)} hiddenChange{\(large.hiddenChange)} resize{\(large.resize)}")
        for (n, r) in [(1_000, small), (10_000, large)] {
            // Heights and layouts on load: the rows in view and the overscan.
            #expect(r.load.heights <= Self.heightBudget, "n=\(n) load asked \(r.load.heights) heights")
            #expect(r.load.laidOut <= Self.layoutBudget, "n=\(n) load laid out \(r.load.laidOut) rows")
            // One event on screen changes: that row alone is laid out and reconfigured.
            #expect(r.visibleChange.laidOut == 1, "n=\(n) one change laid out \(r.visibleChange.laidOut) rows")
            #expect(r.visibleChange.reconfigured == 1, "n=\(n) one change reconfigured \(r.visibleChange.reconfigured) rows")
            #expect(r.visibleChange.configured <= 1, "n=\(n) one change configured \(r.visibleChange.configured) cells")
            #expect(r.visibleChange.heights <= Self.heightBudget, "n=\(n) one change asked \(r.visibleChange.heights) heights")
            // One event off screen changes: nothing is laid out or configured until it scrolls in.
            #expect(r.hiddenChange.laidOut == 0, "n=\(n) an off-screen change laid out \(r.hiddenChange.laidOut) rows")
            #expect(r.hiddenChange.configured == 0, "n=\(n) an off-screen change configured \(r.hiddenChange.configured) cells")
            #expect(r.hiddenChange.heights <= Self.heightBudget, "n=\(n) an off-screen change asked \(r.hiddenChange.heights) heights")
            // A width change: the rows on screen, once.
            #expect(r.resize.laidOut <= Self.layoutBudget, "n=\(n) a resize laid out \(r.resize.laidOut) rows")
            #expect(r.resize.reconfigured <= Self.layoutBudget, "n=\(n) a resize reconfigured \(r.resize.reconfigured) rows")
            #expect(r.resize.configured <= Self.layoutBudget, "n=\(n) a resize configured \(r.resize.configured) cells")
            #expect(r.resize.heights <= Self.heightBudget, "n=\(n) a resize asked \(r.resize.heights) heights")
            // Behaviour: the top visible row stays put across the rotation.
            #expect(r.topBefore != nil, "n=\(n) scrollTo(e20) left no event row at the top")
            #expect(r.topAfter == r.topBefore, "n=\(n) the top row moved from \(r.topBefore ?? "nil") to \(r.topAfter ?? "nil")")
            #expect(r.staleRows.isEmpty, "n=\(n) rows shown at a height not their layout's: \(r.staleRows)")
        }
        // The same counts at 1,000 and 10,000 (within 10%).
        #expect(Self.flat(small.load.heights, large.load.heights), "load heights \(small.load.heights) vs \(large.load.heights)")
        #expect(Self.flat(small.load.laidOut, large.load.laidOut), "load layouts \(small.load.laidOut) vs \(large.load.laidOut)")
        #expect(Self.flat(small.resize.laidOut, large.resize.laidOut), "resize layouts \(small.resize.laidOut) vs \(large.resize.laidOut)")
        #expect(Self.flat(small.resize.heights, large.resize.heights), "resize heights \(small.resize.heights) vs \(large.resize.heights)")
    }
}
#endif
