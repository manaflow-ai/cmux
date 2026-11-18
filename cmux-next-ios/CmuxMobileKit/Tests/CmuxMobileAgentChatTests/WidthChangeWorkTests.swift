import Foundation
import Testing
@testable import CmuxMobileAgentChat
#if os(iOS)
import UIKit

/// A width change (rotation, Split View, Text and Width's column) lays out again only the rows near
/// the screen; the rest keep the heights they had as estimates and are corrected as they come into
/// view. One changed row moves the rows' offsets in O(log n), not by re-summing every row below it.
/// Counted at 1,000 and 10,000 rows: the work per event is the same at both, within 10% (offset
/// writes may grow by the tree's depth, log n).
@MainActor
@Suite(.serialized) struct WidthChangeWorkTests {
    /// Where the reader rests: a fixed distance from the top, so both sizes show the same rows.
    static let readerY: CGFloat = 12_000

    struct Chat {
        let store: AgentChatStore
        let list: ChatTranscriptList
        let surface: AgentChatSurface
        let window: UIWindow
    }

    /// Finished turns making about `rows` rows, in a 390 x 800 window, the reader scrolled up to
    /// `readerY` (not following: nothing spills, and the reader's row holds its place).
    static func chat(rows: Int) -> Chat {
        let probe = ChatTranscriptList(store: Self.store(turns: 10), surface: AgentChatSurface())
        probe.collectionView.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        probe.boundsMayHaveChanged()
        let perTurn = max(1, probe.layout.items.count / 10)
        let store = Self.store(turns: max(1, rows / perTurn))
        let surface = AgentChatSurface()
        surface.following = false
        let list = ChatTranscriptList(store: store, surface: surface)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.addSubview(list.collectionView)
        list.collectionView.frame = host.view.bounds
        list.boundsMayHaveChanged()
        list.collectionView.layoutIfNeeded()
        list.collectionView.contentOffset.y = readerY
        list.collectionView.layoutIfNeeded()
        return Chat(store: store, list: list, surface: surface, window: window)
    }

    static func store(turns: Int) -> AgentChatStore {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.batch((0..<turns).flatMap { SmoothChatTests.turn($0) }))
        return store
    }

    struct WidthStep: CustomStringConvertible {
        var rows = 0
        var weighed = 0
        var reconfigured = 0
        var layoutsAsked = 0
        var heightsResolved = 0
        var offsetWrites = 0
        var cellsMeasured = 0
        var anchorMoved: CGFloat = 0
        var description: String {
            "rows \(rows): weighed \(weighed), reconfigured \(reconfigured), off-main layouts asked \(layoutsAsked), "
                + "heights looked up \(heightsResolved), offset writes \(offsetWrites), cells measured \(cellsMeasured), "
                + "reader's row moved \(anchorMoved) pt"
        }
    }

    /// One width step, 390 to 430 pt, with the reader scrolled up.
    static func widthStep(rows: Int) throws -> WidthStep {
        let chat = chat(rows: rows)
        defer { chat.window.isHidden = true }
        let list = chat.list, view = list.collectionView
        let inset = view.adjustedContentInset.top
        let anchor = try #require(list.layout.firstRow(below: view.contentOffset.y + inset))
        let screenTop = anchor.top - view.contentOffset.y
        let weighed = list.rowsWeighed, asked = list.layoutsAsked
        let resolved = list.layout.heightsResolved, writes = list.layout.offsetWrites, measured = list.layout.measurements
        view.frame.size.width = 430
        list.boundsMayHaveChanged()
        view.layoutIfNeeded()
        var step = WidthStep()
        step.rows = list.layout.items.count
        step.weighed = list.rowsWeighed - weighed
        step.reconfigured = list.lastReconfigured
        step.layoutsAsked = list.layoutsAsked - asked
        step.heightsResolved = list.layout.heightsResolved - resolved
        step.offsetWrites = list.layout.offsetWrites - writes
        step.cellsMeasured = list.layout.measurements - measured
        let top = try #require(list.layout.top(of: anchor.id))
        step.anchorMoved = abs((top - view.contentOffset.y) - screenTop)
        return step
    }

    static func flat(_ small: Int, _ large: Int) -> Bool { Double(large) <= Double(small) * 1.1 + 2 }

    @Test func aWidthChangeLaysOutOnlyTheRowsNearTheScreen() throws {
        let small = try Self.widthStep(rows: 1_000)
        let large = try Self.widthStep(rows: 10_000)
        print("width step: \(small)")
        print("width step: \(large)")
        #expect(large.rows > 9 * small.rows, "\(small.rows) and \(large.rows) rows")
        // Rows near the screen (one screen each side, whole turns): never every row.
        for step in [small, large] {
            #expect(step.weighed <= 200, "\(step)")
            #expect(step.reconfigured <= 200, "\(step)")
            #expect(step.layoutsAsked <= 200, "\(step)")
            #expect(step.heightsResolved <= 200, "\(step)")
            #expect(step.anchorMoved <= 1, "\(step)")
        }
        #expect(Self.flat(small.weighed, large.weighed), "weighed \(small.weighed) at \(small.rows) rows, \(large.weighed) at \(large.rows)")
        #expect(Self.flat(small.reconfigured, large.reconfigured), "reconfigured \(small.reconfigured), \(large.reconfigured)")
        #expect(Self.flat(small.layoutsAsked, large.layoutsAsked), "layouts asked \(small.layoutsAsked), \(large.layoutsAsked)")
        #expect(Self.flat(small.heightsResolved, large.heightsResolved), "heights looked up \(small.heightsResolved), \(large.heightsResolved)")
        #expect(Self.flat(small.cellsMeasured, large.cellsMeasured), "cells measured \(small.cellsMeasured), \(large.cellsMeasured)")
        // Offsets: each row whose height changed (looked up again, or measured by its cell) writes at
        // most the tree's depth (log n: 10 to 14 levels), never a pass over the rows.
        for step in [small, large] {
            #expect(step.offsetWrites <= (step.heightsResolved + step.cellsMeasured + 2) * (Self.depth(step.rows) + 1), "\(step)")
        }
    }

    /// Rows that come into view after a width change take their heights at the new width: the same
    /// estimates a list opened at that width gives them.
    @Test func rowsComingIntoViewAfterAWidthChangeAreLaidOutAtTheNewWidth() async throws {
        let chat = Self.chat(rows: 1_000)
        defer { chat.window.isHidden = true }
        let list = chat.list, view = list.collectionView
        view.frame.size.width = 430
        list.boundsMayHaveChanged()
        view.layoutIfNeeded()
        // To the top, past every row laid out at the old width.
        view.contentOffset.y = 0
        view.layoutIfNeeded()
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(20))
            view.layoutIfNeeded()
        }
        let fresh = ChatTranscriptList(store: chat.store, surface: AgentChatSurface())
        fresh.collectionView.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
        fresh.boundsMayHaveChanged()
        let freshItems = Dictionary(fresh.layout.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = list.visibleRowIDs
        #expect(!shown.isEmpty)
        for id in shown {
            guard let row = list.layout.row(of: id), row < list.layout.items.count, let theirs = freshItems[id] else { continue }
            let mine = list.layout.items[row]
            guard !mine.exact, !theirs.exact else { continue }
            #expect(mine.estimate == theirs.estimate, "\(id) estimated at \(mine.estimate), a list opened at 430 pt says \(theirs.estimate)")
        }
        #expect(list.layout.items.map(\.id) == fresh.layout.items.map(\.id))
    }

    // MARK: The layout alone

    static func layout(rows: Int) -> (layout: ChatTranscriptLayout, view: UICollectionView) {
        let layout = ChatTranscriptLayout()
        let view = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), collectionViewLayout: layout)
        layout.setItems((0..<rows).map { .init(id: "r\($0)", revision: 0, gap: 8, estimate: CGFloat(30 + $0 % 7 * 10)) })
        _ = layout.top(of: "r0")
        return (layout, view)
    }

    /// The tops a plain sum gives (gap, then the rows above).
    static func summedTops(_ layout: ChatTranscriptLayout) -> [CGFloat] {
        var y: CGFloat = 0
        return layout.items.map { item in
            y += item.gap
            let top = y
            y += layout.height(of: item.id) ?? 0
            return top
        }
    }

    struct LayoutWork: CustomStringConvertible {
        var rows = 0
        var resolved = 0
        var writes = 0
        var description: String { "rows \(rows): heights looked up \(resolved), offset writes \(writes)" }
    }

    static func work(_ layout: ChatTranscriptLayout, _ change: () -> Void) -> LayoutWork {
        let resolved = layout.heightsResolved, writes = layout.offsetWrites
        change()
        _ = layout.top(of: layout.items.last?.id ?? "")
        return LayoutWork(rows: layout.items.count, resolved: layout.heightsResolved - resolved, writes: layout.offsetWrites - writes)
    }

    /// The tree's depth for `n` rows.
    static func depth(_ n: Int) -> Int { Int(log2(Double(n)).rounded(.up)) }

    @Test(arguments: [1_000, 10_000])
    func oneChangedRowMovesTheOffsetsInLogTime(rows: Int) throws {
        let (layout, view) = Self.layout(rows: rows)
        _ = view
        // A changed row at the top (its content changed: a new revision and estimate).
        let changed = Self.work(layout) {
            var items = layout.items
            items[0].revision = 1
            items[0].estimate = 75
            layout.setItems(items)
        }
        print("one changed row: \(changed)")
        #expect(changed.resolved <= 2, "\(changed)")
        #expect(changed.writes <= Self.depth(rows) + 2, "\(changed)")
        // A row that measured itself (a disclosure's spring lays it out).
        let measured = Self.work(layout) { _ = layout.layOut("r1", at: 120) }
        print("one measured row: \(measured)")
        #expect(measured.writes <= Self.depth(rows) + 2, "\(measured)")
        // A new row at the end (a streamed block).
        let appended = Self.work(layout) {
            layout.setItems(layout.items + [.init(id: "new", revision: 0, gap: 8, estimate: 44)])
        }
        print("one appended row: \(appended)")
        #expect(appended.resolved <= 2, "\(appended)")
        #expect(appended.writes <= Self.depth(rows) + 2, "\(appended)")
        // One scroll step: no height or offset touched.
        let scrolled = Self.work(layout) {
            _ = layout.layoutAttributesForElements(in: CGRect(x: 0, y: 5_040, width: 390, height: 800))
        }
        print("one scroll step: \(scrolled)")
        #expect(scrolled.resolved == 0 && scrolled.writes == 0, "\(scrolled)")
        // A new width: rows keep their heights until a cell measures them again.
        let resized = Self.work(layout) {
            view.frame.size.width = 430
            _ = layout.layoutAttributesForElements(in: CGRect(x: 0, y: 5_040, width: 430, height: 800))
        }
        print("one width step: \(resized)")
        #expect(resized.resolved <= 2 && resized.writes <= 2, "\(resized)")
        // Every row still where a plain sum puts it.
        let tops = Self.summedTops(layout)
        for (row, item) in layout.items.enumerated() where row % 97 == 0 || row >= layout.items.count - 3 {
            let top = try #require(layout.top(of: item.id))
            #expect(abs(top - tops[row]) < 0.01, "\(item.id) at \(top), summed \(tops[row])")
        }
        let last = try #require(layout.items.last)
        #expect(abs(layout.contentHeight - ((layout.top(of: last.id) ?? 0) + (layout.height(of: last.id) ?? 0) + layout.trailingGap)) < 0.01)
        // The row at an offset: the first row whose bottom is at or below it.
        let probe = tops[rows / 2] + 1
        let found = try #require(layout.firstRow(below: probe))
        #expect(found.id == layout.items[rows / 2].id, "row at \(probe): \(found.id)")
    }
}
#endif
