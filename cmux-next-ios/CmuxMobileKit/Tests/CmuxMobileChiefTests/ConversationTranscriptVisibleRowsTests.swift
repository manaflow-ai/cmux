#if canImport(UIKit)
import Testing
import UIKit
@testable import CmuxConversationUI

/// The Chief conversation transcript (CmuxConversation's
/// `ConversationTranscriptLayout`) lays out the rows in view, never the
/// whole conversation. Leo, 2026-11-18: "we draw the visible area, right?
/// Like, that's what we're supposed to do."
///
/// The real layout, in a real collection view, over a data source that
/// counts every row the layout asks it to measure (`transcriptHeight`, the
/// text layout of a message in the app) and every cell it configures. Each
/// event is run at 1,000 and 10,000 rows:
///   1. rows measured per event stay within the rows in view plus one
///      viewport of overscan on each side,
///   2. a one-item change measures and configures only that row,
///   3. no event measures every row, and the counts are the same at both
///      sizes (within 10%).
/// CmuxConversation's own test targets are not run by any pull request
/// check (scripts/ci/swift-test-targets.json); this kit runs on the iOS
/// simulator in cmux-next-ios-kit.yml.
@MainActor
@Suite(.serialized)
struct ConversationTranscriptVisibleRowsTests {
    static let portrait = CGSize(width: 402, height: 874)
    static let landscape = CGSize(width: 874, height: 402)

    struct Counts: CustomStringConvertible {
        var oneItemChange = Event()
        var append = Event()
        var scrollStep = Event()
        var widthChange = Event()
        var textSizeChange = Event()

        var description: String {
            "oneItemChange \(oneItemChange), append \(append), scrollStep(max of 40) \(scrollStep), "
                + "widthChange \(widthChange), textSizeChange \(textSizeChange)"
        }
    }

    struct Event: CustomStringConvertible {
        var measured = 0
        var configured = 0
        var description: String { "measured=\(measured) configured=\(configured)" }
    }

    @Test func rowsLaidOutPerEventAreBoundedByTheViewportAndFlatInLength() {
        let small = Self.run(count: 1_000)
        let large = Self.run(count: 10_000)
        print("transcript-visible-rows N=1000 \(small.counts)")
        print("transcript-visible-rows N=10000 \(large.counts)")
        for (count, result) in [(1_000, small), (10_000, large)] {
            let counts = result.counts
            // Rule 2: a one-item change measures and configures that row; the
            // reader stays on the newest message, so one row may scroll into view.
            #expect(counts.oneItemChange.measured <= 2, "N=\(count): one changed row measured \(counts.oneItemChange.measured) rows")
            #expect(counts.oneItemChange.configured <= 2, "N=\(count): one changed row configured \(counts.oneItemChange.configured) cells")
            // A new message at the bottom: that row, and the rows it scrolls into view.
            #expect(counts.append.measured <= 3, "N=\(count): one new row measured \(counts.append.measured) rows")
            #expect(counts.append.configured <= 3, "N=\(count): one new row configured \(counts.append.configured) cells")
            // Rule 1: a scroll step measures at most the rows entering the overscan.
            #expect(counts.scrollStep.measured <= 4, "N=\(count): one scroll step measured \(counts.scrollStep.measured) rows")
            #expect(counts.scrollStep.configured <= 6, "N=\(count): one scroll step configured \(counts.scrollStep.configured) cells")
            // Rule 1 on a width or text size change: rows in view plus overscan
            // (and the newest rows a reader pinned to the bottom lands on), never all.
            #expect(counts.widthChange.measured <= result.widthBudget, "N=\(count): a width change measured \(counts.widthChange.measured) rows (budget \(result.widthBudget))")
            #expect(counts.textSizeChange.measured <= result.textSizeBudget, "N=\(count): a text size change measured \(counts.textSizeChange.measured) rows (budget \(result.textSizeBudget))")
            #expect(counts.widthChange.configured <= result.widthBudget, "N=\(count): a width change configured \(counts.widthChange.configured) cells")
            #expect(result.pinnedAfterEveryEvent, "N=\(count): the newest row left the bottom of the view")
            #expect(result.keptVisibleRowOnWidthChange, "N=\(count): a reader scrolled up lost the row in view on a width change")
        }
        // Rule 3: flat in N (within 10%, or 2 rows when the counts are tiny).
        let pairs: [(String, Int, Int)] = [
            ("oneItemChange", small.counts.oneItemChange.measured, large.counts.oneItemChange.measured),
            ("append", small.counts.append.measured, large.counts.append.measured),
            ("scrollStep", small.counts.scrollStep.measured, large.counts.scrollStep.measured),
            ("widthChange", small.counts.widthChange.measured, large.counts.widthChange.measured),
            ("textSizeChange", small.counts.textSizeChange.measured, large.counts.textSizeChange.measured),
        ]
        for (name, a, b) in pairs {
            #expect(abs(a - b) <= max(2, max(a, b) / 10), "\(name): \(a) rows measured at 1,000 but \(b) at 10,000")
        }
    }

    struct Result {
        var counts = Counts()
        var widthBudget = 0
        var textSizeBudget = 0
        var pinnedAfterEveryEvent = true
        var keptVisibleRowOnWidthChange = false
    }

    static func run(count: Int) -> Result {
        let rows = FakeTranscript(count: count)
        let layout = ConversationTranscriptLayout()
        layout.dataSource = rows
        let window = UIWindow(frame: CGRect(origin: .zero, size: portrait))
        let view = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: FakeTranscript.reuseID)
        view.dataSource = rows
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        var result = Result()

        // The conversation opens on its newest message.
        view.layoutIfNeeded()
        pinToBottom(view)
        result.pinnedAfterEveryEvent = isPinned(view, rows: rows)

        // One item changes: the newest reply grows a line (a streaming answer).
        var before = rows.snapshot()
        let last = rows.ids.count - 1
        rows.change(at: last, by: 22)
        rows.edits = (deleted: [], inserted: [], updated: [last])
        view.performBatchUpdates({})
        view.reconfigureItems(at: [IndexPath(item: last, section: 0)])
        view.layoutIfNeeded()
        pinToBottom(view)
        result.counts.oneItemChange = rows.since(before)
        result.pinnedAfterEveryEvent = result.pinnedAfterEveryEvent && isPinned(view, rows: rows)

        // A new message arrives at the bottom.
        before = rows.snapshot()
        let inserted = rows.append()
        rows.edits = (deleted: [], inserted: [inserted], updated: [])
        view.performBatchUpdates { view.insertItems(at: [IndexPath(item: inserted, section: 0)]) }
        view.layoutIfNeeded()
        pinToBottom(view)
        result.counts.append = rows.since(before)
        result.pinnedAfterEveryEvent = result.pinnedAfterEveryEvent && isPinned(view, rows: rows)

        // The reader scrolls up, 30 pt a step (a slow drag).
        for _ in 0..<40 {
            before = rows.snapshot()
            view.contentOffset.y -= 30
            view.layoutIfNeeded()
            let step = rows.since(before)
            result.counts.scrollStep.measured = max(result.counts.scrollStep.measured, step.measured)
            result.counts.scrollStep.configured = max(result.counts.scrollStep.configured, step.configured)
        }

        // Scrolled up, the device rotates: the row in view stays in view.
        let shown = firstVisibleID(view, rows: rows)
        view.frame.size = landscape
        view.reloadData()
        view.layoutIfNeeded()
        let stillShown = visibleIDs(view, rows: rows)
        result.keptVisibleRowOnWidthChange = shown.map { stillShown.contains($0) } ?? false
        view.frame.size = portrait
        view.reloadData()
        view.layoutIfNeeded()
        pinToBottom(view)

        // Pinned to the newest message, the device rotates (the controller
        // reloads for the new width and stays on the newest message).
        before = rows.snapshot()
        view.frame.size = landscape
        view.reloadData()
        view.layoutIfNeeded()
        pinToBottom(view)
        result.counts.widthChange = rows.since(before)
        result.widthBudget = budget(view, rows: rows)
        result.pinnedAfterEveryEvent = result.pinnedAfterEveryEvent && isPinned(view, rows: rows)
        view.frame.size = portrait
        view.layoutIfNeeded()
        pinToBottom(view)

        // Dynamic Type: every row is taller (the controller's
        // relayoutForTextMetrics: invalidate, reload, back to the newest).
        before = rows.snapshot()
        rows.textScale = 1.3
        layout.invalidateLayout()
        view.reloadData()
        view.layoutIfNeeded()
        pinToBottom(view)
        result.counts.textSizeChange = rows.since(before)
        result.textSizeBudget = budget(view, rows: rows)
        result.pinnedAfterEveryEvent = result.pinnedAfterEveryEvent && isPinned(view, rows: rows)
        return result
    }

    /// Rows in view plus one viewport of overscan on each side, counted at
    /// the shortest row, plus a viewport of the newest rows (what a reader
    /// pinned to the bottom lands on).
    static func budget(_ view: UICollectionView, rows: FakeTranscript) -> Int {
        let perViewport = Int((view.bounds.height / rows.shortestExtent(width: view.bounds.width)).rounded(.up)) + 1
        return perViewport * 4
    }

    static func pinToBottom(_ view: UICollectionView) {
        view.layoutIfNeeded()
        let insets = view.adjustedContentInset
        view.contentOffset.y = max(-insets.top, view.contentSize.height + insets.bottom - view.bounds.height)
        view.layoutIfNeeded()
    }

    static func isPinned(_ view: UICollectionView, rows: FakeTranscript) -> Bool {
        let last = IndexPath(item: rows.ids.count - 1, section: 0)
        guard let frame = view.collectionViewLayout.layoutAttributesForItem(at: last)?.frame else { return false }
        return abs(frame.maxY - view.bounds.maxY) <= 8 && view.bounds.intersects(frame)
    }

    static func visibleIDs(_ view: UICollectionView, rows: FakeTranscript) -> Set<String> {
        let items = view.collectionViewLayout.layoutAttributesForElements(in: view.bounds) ?? []
        return Set(items.map { rows.ids[$0.indexPath.item] })
    }

    static func firstVisibleID(_ view: UICollectionView, rows: FakeTranscript) -> String? {
        let items = view.collectionViewLayout.layoutAttributesForElements(in: view.bounds) ?? []
        // The top row in view (a rotation keeps the offset, and the view gets shorter).
        let top = view.bounds.minY + view.adjustedContentInset.top + 1
        return items.sorted { $0.indexPath.item < $1.indexPath.item }
            .first { $0.frame.maxY > top }.map { rows.ids[$0.indexPath.item] }
    }
}

/// A transcript of `count` rows whose heights rewrap with the width and grow
/// with the text size, counting what the layout asks of it.
@MainActor
final class FakeTranscript: NSObject, ConversationTranscriptLayoutDataSource, UICollectionViewDataSource {
    static let reuseID = "row"
    var ids: [String]
    private var base: [CGFloat]
    private var positions: [String: Int] = [:]
    /// Every height changes with it (a text size change); the controller's
    /// `rowMetricsEpoch` is the same signal.
    var textScale: CGFloat = 1 { didSet { metricsEpoch += 1 } }
    private(set) var metricsEpoch = 0
    var edits: (deleted: [Int], inserted: [Int], updated: [Int])?
    private(set) var measured = 0
    private(set) var configured = 0

    init(count: Int) {
        ids = (0..<count).map { "row-\($0)" }
        // 1 to 6 lines of text at the portrait width.
        base = (0..<count).map { CGFloat(38 + ($0 * 7919) % 6 * 21) }
        super.init()
        for (index, id) in ids.enumerated() { positions[id] = index }
    }

    func change(at index: Int, by delta: CGFloat) { base[index] += delta }

    func append() -> Int {
        let index = ids.count
        let id = "row-\(index)"
        ids.append(id)
        base.append(59)
        positions[id] = index
        return index
    }

    func snapshot() -> (Int, Int) { (measured, configured) }

    func since(_ before: (Int, Int)) -> ConversationTranscriptVisibleRowsTests.Event {
        .init(measured: measured - before.0, configured: configured - before.1)
    }

    func shortestExtent(width: CGFloat) -> CGFloat {
        height(38, width: width) + 2
    }

    private func height(_ base: CGFloat, width: CGFloat) -> CGFloat {
        // Text rewraps: twice the width, about half the lines (never under one line).
        max(38, (base * 402 / max(1, width)).rounded()) * textScale
    }

    // MARK: ConversationTranscriptLayoutDataSource

    func transcriptItemCount() -> Int { ids.count }
    func transcriptWillPrepare(width: CGFloat) {}
    func transcriptDidPrepare() {}
    func transcriptHeight(at index: Int, width: CGFloat) -> CGFloat {
        measured += 1
        return height(base[index], width: width)
    }
    func transcriptSpacing(before index: Int) -> CGFloat { index % 4 == 0 ? 10 : 2 }
    func transcriptBottomOverhang() -> CGFloat { 0 }
    func transcriptAppearance(at index: Int) -> ConversationTranscriptLayout.Appearance { .none }
    func transcriptItemIDs() -> [String] { ids }
    func transcriptIndex(ofItemID id: String) -> Int? { positions[id] }
    // The update being applied, as the controller describes it to the layout.
    func transcriptTakeEdits() -> (deleted: [Int], inserted: [Int], updated: [Int])? {
        defer { edits = nil }
        return edits
    }
    func transcriptDidShiftContent(by delta: CGFloat) {}
    func transcriptMetricsEpoch() -> Int { metricsEpoch }

    // MARK: UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { ids.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        configured += 1
        return collectionView.dequeueReusableCell(withReuseIdentifier: Self.reuseID, for: indexPath)
    }
}
#endif
