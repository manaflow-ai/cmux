#if canImport(UIKit)
import CmuxConversationGeometry
import UIKit

@MainActor
protocol ConversationTranscriptLayoutDataSource: AnyObject {
    func transcriptItemCount() -> Int
    /// Called once at the start of each layout pass, before any height.
    func transcriptWillPrepare(width: CGFloat)
    /// Called at the end of each layout pass.
    func transcriptDidPrepare()
    func transcriptHeight(at index: Int, width: CGFloat) -> CGFloat
    /// Vertical gap above item `index`.
    func transcriptSpacing(before index: Int) -> CGFloat
    /// How far the last row's tail hangs below its body with nothing under
    /// it; Messages lets it hang into the bottom margin.
    func transcriptBottomOverhang() -> CGFloat
    func transcriptAppearance(at index: Int) -> ConversationTranscriptLayout.Appearance
    /// Stable row identities, in order (what keeps a row's pixel phase).
    func transcriptItemIDs() -> [String]
    func transcriptIndex(ofItemID id: String) -> Int?
    /// The rows the update being applied deleted (old indices), inserted and
    /// changed (new indices), taken by the next layout pass. Nil when the
    /// rows did not change in a batch described here: rows whose identities
    /// moved then all start over as estimates.
    func transcriptTakeEdits() -> (deleted: [Int], inserted: [Int], updated: [Int])?
    /// Changes whenever every height may have changed (text size, width,
    /// margins, display scale): the layout measures rows again as they come
    /// into view, and keeps the old heights as estimates until then.
    func transcriptMetricsEpoch() -> Int
    /// Rows above the visible ones were measured as they came into view, and
    /// the content offset moved by `delta` so the rows in view stay still.
    func transcriptDidShiftContent(by delta: CGFloat)
}

/// A single-column transcript layout. Content shorter than the viewport sits
/// at the top under the header, like Messages on iOS 26.5 and 27.0 (a new
/// conversation's first messages start just below the service line); longer
/// content scrolls to its bottom.
///
/// Only the rows in view are measured (Leo, 2026-11-18: "we draw the visible
/// area, right? Like, that's what we're supposed to do"). Row offsets live
/// in a prefix-sum index (`ConversationTranscriptOffsets`), so a pass costs
/// the rows it measures and places, not the conversation's length: a batch
/// measures the rows it inserts or changes; a width, text size or scale
/// change keeps every height as an estimate and measures the rows from the
/// first visible one through one viewport below, and the newest rows (what a
/// reader pinned to the bottom lands on); rows scrolling into the viewport
/// of overscan above are measured then, with the content offset moved by
/// what they changed so the rows in view stay still.
final class ConversationTranscriptLayout: UICollectionViewLayout {
    enum Appearance {
        case none
        /// New incoming bubble: grows from its tail corner.
        case incoming
        /// Outgoing bubble placed by the send animation; the cell is hidden meanwhile.
        case sent
        /// Plain fade (typing indicator removal, loading row).
        case fade
    }

    /// What layout passes did, summed since the layout was made (count tests
    /// and the DEBUG probe take differences).
    struct Counters: Equatable {
        var prepares = 0
        /// Rows whose height (and gap above) the data source was asked for.
        var rowsMeasured = 0
        /// Gaps measured alone (the row above changed).
        var gapsMeasured = 0
        /// Rows given an estimate without asking the data source (a reset).
        var rowsEstimated = 0
        /// Layout attributes made (one frame each, for UIKit).
        var attributesBuilt = 0
    }

    private(set) var counters = Counters()

    /// Rows measured past the visible ones, in viewports (one each side, the
    /// visible-rows rule's default overscan; the newest rows' reach is one
    /// viewport plus this).
    static let overscan: CGFloat = 1
    /// A row's estimated extent before any row was measured.
    static let firstEstimate: CGFloat = 60

    weak var dataSource: (any ConversationTranscriptLayoutDataSource)?
    private var offsets = ConversationTranscriptOffsets()
    /// The identities `offsets` holds, in order.
    private var itemIDs: [String] = []
    private var metricsEpoch: Int?
    private var phase: CGFloat = 0
    private var scale: CGFloat = 1
    private var width: CGFloat = -1
    /// `topPadding` as of the last pass (frames are computed lazily).
    private var preparedTopPadding: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var measuredExtents: CGFloat = 0
    private var measuredRows = 0
    /// Made on first request and kept until offsets change: a pass
    /// allocates attributes only for the rows UIKit asks about.
    private var cachedAttributes: [Int: UICollectionViewLayoutAttributes] = [:]
    var topPadding: CGFloat = 0

    private var estimate: CGFloat {
        measuredRows > 0 ? measuredExtents / CGFloat(measuredRows) : Self.firstEstimate
    }

    override func prepare() {
        super.prepare()
        guard let collectionView, let dataSource else { return }
        counters.prepares += 1
        let bounds = collectionView.bounds
        dataSource.transcriptWillPrepare(width: bounds.width)
        scale = max(1, collectionView.traitCollection.displayScale)
        // The rows on screen in the last pass, to keep their pixel phase.
        let anchors = visibleAnchors(in: bounds)
        let epoch = dataSource.transcriptMetricsEpoch()
        if bounds.width != width || epoch != metricsEpoch {
            width = bounds.width
            metricsEpoch = epoch
            offsets.invalidateAll()
        }
        let ids = dataSource.transcriptItemIDs()
        var changed: [Int] = []
        var gaps: [Int] = []
        if let edits = dataSource.transcriptTakeEdits(), Self.edits(edits, take: offsets.count, to: ids.count) {
            gaps = offsets.apply(deleted: edits.deleted, inserted: edits.inserted, estimate: estimate)
            changed = Array(Set(edits.inserted + edits.updated)).sorted()
            gaps += changed.map { $0 + 1 }
        } else if ids.count != offsets.count || !Self.sameStorage(ids, itemIDs) {
            offsets.reset(count: ids.count, estimate: estimate)
            counters.rowsEstimated += ids.count
        }
        itemIDs = ids
        preparedTopPadding = topPadding
        for index in changed { measure(index) }
        let changedSet = Set(changed)
        for index in Set(gaps) where index > 0 && index < offsets.count && !changedSet.contains(index) && offsets.isFresh(index) {
            offsets.setSpacing(index, dataSource.transcriptSpacing(before: index))
            counters.gapsMeasured += 1
        }
        measureRowsInView(bounds)
        // Rows stack at their unrounded heights and each top snaps to the
        // pixel grid (see ConversationTranscriptPixelGrid), with the phase
        // that keeps the rows on screen where they were on it.
        phase = keptPhase(anchors)
        contentHeight = computedContentHeight()
        cachedAttributes.removeAll(keepingCapacity: true)
        dataSource.transcriptDidPrepare()
    }

    /// Whether `edits` take `old` rows to `new` ones with every index in range.
    private static func edits(_ edits: (deleted: [Int], inserted: [Int], updated: [Int]), take old: Int, to new: Int) -> Bool {
        let deleted = Set(edits.deleted), inserted = Set(edits.inserted)
        guard old - deleted.count + inserted.count == new else { return false }
        return deleted.allSatisfy { $0 >= 0 && $0 < old }
            && inserted.allSatisfy { $0 >= 0 && $0 < new }
            && edits.updated.allSatisfy { $0 >= 0 && $0 < new }
    }

    /// The same array (the data source handed back the identities it gave
    /// the last pass): no row came, went or moved.
    private static func sameStorage(_ a: [String], _ b: [String]) -> Bool {
        guard a.count == b.count else { return false }
        guard !a.isEmpty else { return true }
        return a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
    }

    private func measure(_ index: Int) {
        guard let dataSource else { return }
        let spacing = index == 0 ? 0 : dataSource.transcriptSpacing(before: index)
        let height = dataSource.transcriptHeight(at: index, width: width)
        offsets.setMeasured(index, spacing: spacing, height: height)
        counters.rowsMeasured += 1
        measuredExtents += spacing + height
        measuredRows += 1
    }

    /// Measures the rows not measured yet among those UIKit shows next: from
    /// the first visible row through one viewport of overscan below it, and
    /// the newest rows over one viewport plus the overscan (what a reader
    /// pinned to the bottom sees). Neither moves a row above the first
    /// visible one, so the rows in view stay where they are.
    private func measureRowsInView(_ bounds: CGRect) {
        guard offsets.staleCount > 0 else { return }
        let reach = bounds.height * Self.overscan
        var index = firstRow(at: bounds.minY)
        while index < offsets.count, contentTop(of: index) <= bounds.maxY + reach {
            if !offsets.isFresh(index) { measure(index) }
            index += 1
        }
        var newest = offsets.count - 1
        while newest >= 0, offsets.total - offsets.bottom(of: newest) < bounds.height + reach {
            if !offsets.isFresh(newest) { measure(newest) }
            newest -= 1
        }
    }

    /// The rows intersecting `bounds` and their tops before snapping, in order.
    private func visibleAnchors(in bounds: CGRect) -> [(id: String, top: CGFloat)] {
        guard offsets.count > 0, offsets.count == itemIDs.count else { return [] }
        var anchors: [(id: String, top: CGFloat)] = []
        var index = firstRow(at: bounds.minY)
        while index < offsets.count, contentTop(of: index) <= bounds.maxY {
            anchors.append((itemIDs[index], preparedTopPadding + offsets.top(of: index) + phase))
            index += 1
        }
        return anchors
    }

    /// The phase that keeps the first row on screen in the last pass, and
    /// still here, on the pixel offset it had.
    private func keptPhase(_ anchors: [(id: String, top: CGFloat)]) -> CGFloat {
        guard let dataSource else { return phase }
        for anchor in anchors {
            guard let index = dataSource.transcriptIndex(ofItemID: anchor.id), index < offsets.count else { continue }
            return ConversationTranscriptPixelGrid.phase(placing: preparedTopPadding + offsets.top(of: index), likePreviousTop: anchor.top, scale: scale)
        }
        return phase
    }

    private func computedContentHeight() -> CGFloat {
        let overhang = offsets.count > 0 ? (dataSource?.transcriptBottomOverhang() ?? 0) : 0
        return preparedTopPadding + offsets.total + phase + 6 - overhang
    }

    /// Row `index`'s top in content coordinates, before snapping.
    private func contentTop(of index: Int) -> CGFloat {
        preparedTopPadding + offsets.top(of: index) + phase
    }

    /// The first row whose bottom reaches `y` (content coordinates), or
    /// `count`. Half a pixel of snapping either way is covered.
    private func firstRow(at y: CGFloat) -> Int {
        let count = offsets.count
        var index = offsets.firstRow(endingBelow: y - preparedTopPadding - phase - 1)
        while index < count, snappedFrame(at: index).maxY < y { index += 1 }
        return index
    }

    private func snappedFrame(at index: Int) -> CGRect {
        let y = ConversationTranscriptPixelGrid.snap(preparedTopPadding + offsets.top(of: index), phase: phase, scale: scale)
        return CGRect(x: 0, y: y, width: max(0, width), height: offsets.height(at: index))
    }

    private func attributes(at index: Int) -> UICollectionViewLayoutAttributes {
        if let attributes = cachedAttributes[index] { return attributes }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
        attributes.frame = snappedFrame(at: index)
        cachedAttributes[index] = attributes
        counters.attributesBuilt += 1
        return attributes
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        itemRange(in: rect).map { attributes(at: $0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < offsets.count else { return nil }
        return attributes(at: indexPath.item)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        if newBounds.width != collectionView?.bounds.width || newBounds.height != collectionView?.bounds.height { return true }
        return hasUnmeasuredRows(around: newBounds)
    }

    /// Whether a row in `bounds` or its overscan was not measured yet.
    private func hasUnmeasuredRows(around bounds: CGRect) -> Bool {
        guard offsets.staleCount > 0 else { return false }
        let reach = bounds.height * Self.overscan
        var index = firstRow(at: bounds.minY - reach)
        while index < offsets.count, contentTop(of: index) <= bounds.maxY + reach {
            if !offsets.isFresh(index) { return true }
            index += 1
        }
        return false
    }

    /// A scroll brought rows not measured yet into the overscan: they are
    /// measured here, and the content offset moves by what the rows above
    /// the first visible one changed, so the rows in view stay still (or,
    /// with the newest message in view, by what the content's height
    /// changed, so it stays on the bottom).
    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        guard let collectionView, newBounds.size == collectionView.bounds.size, offsets.staleCount > 0, offsets.count > 0 else { return context }
        let anchor = firstRow(at: newBounds.minY)
        guard anchor < offsets.count else { return context }
        let anchorFrame = snappedFrame(at: anchor)
        let anchorTop = contentTop(of: anchor)
        let heightBefore = contentHeight
        let showsNewest = newBounds.maxY >= heightBefore - 1
        let reach = newBounds.height * Self.overscan
        var measuredAny = false
        var index = firstRow(at: newBounds.minY - reach)
        while index < offsets.count, contentTop(of: index) <= newBounds.maxY + reach {
            if !offsets.isFresh(index) {
                measure(index)
                measuredAny = true
            }
            index += 1
        }
        guard measuredAny else { return context }
        phase = ConversationTranscriptPixelGrid.phase(placing: preparedTopPadding + offsets.top(of: anchor), likePreviousTop: anchorTop, scale: scale)
        contentHeight = computedContentHeight()
        cachedAttributes.removeAll(keepingCapacity: true)
        let shift = showsNewest ? contentHeight - heightBefore : snappedFrame(at: anchor).minY - anchorFrame.minY
        context.contentSizeAdjustment = CGSize(width: 0, height: contentHeight - heightBefore)
        if shift != 0 {
            context.contentOffsetAdjustment = CGPoint(x: 0, y: shift)
            dataSource?.transcriptDidShiftContent(by: shift)
        }
        return context
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let attributes = layoutAttributesForItem(at: itemIndexPath)?.copy() as? UICollectionViewLayoutAttributes else { return nil }
        switch dataSource?.transcriptAppearance(at: itemIndexPath.item) ?? .none {
        case .none:
            return attributes
        case .incoming:
            // Pop in from the leading bottom corner.
            let scale: CGFloat = 0.6
            attributes.transform = CGAffineTransform(translationX: -attributes.frame.width * (1 - scale) / 2, y: attributes.frame.height * (1 - scale) / 2)
                .scaledBy(x: scale, y: scale)
            attributes.alpha = 0
        case .sent:
            attributes.alpha = 0
        case .fade:
            attributes.alpha = 0
        }
        return attributes
    }

    /// Measures now the rows a scroll to row `index` crosses and lands among
    /// (from the rows in view to one viewport of overscan past the target),
    /// so an animated jump passes only measured rows and lands where
    /// `frame(at:)` says; the cost is the jump's distance, not the
    /// conversation's length. Returns how far the rows in view moved (the
    /// rows above them changed) for the caller to move the content offset
    /// by, or nil when every such row was measured already.
    func measureRowsForJump(to index: Int) -> CGFloat? {
        guard let collectionView, index >= 0, index < offsets.count, offsets.staleCount > 0 else { return nil }
        let bounds = collectionView.bounds
        let reach = bounds.height * Self.overscan
        let first = firstRow(at: bounds.minY)
        guard first < offsets.count else { return nil }
        let anchorFrame = snappedFrame(at: first)
        let anchorTop = contentTop(of: first)
        var measuredAny = false
        if index < first {
            var row = first - 1
            while row >= 0, contentTop(of: row) >= contentTop(of: index) - reach {
                if !offsets.isFresh(row) {
                    measure(row)
                    measuredAny = true
                }
                row -= 1
            }
        } else {
            var row = first
            while row < offsets.count, contentTop(of: row) <= contentTop(of: index) + bounds.height + reach {
                if !offsets.isFresh(row) {
                    measure(row)
                    measuredAny = true
                }
                row += 1
            }
        }
        guard measuredAny else { return nil }
        phase = ConversationTranscriptPixelGrid.phase(placing: preparedTopPadding + offsets.top(of: first), likePreviousTop: anchorTop, scale: scale)
        contentHeight = computedContentHeight()
        cachedAttributes.removeAll(keepingCapacity: true)
        return snappedFrame(at: first).minY - anchorFrame.minY
    }

    /// Items whose frames intersect `rect` (an index search, no attributes).
    func itemRange(in rect: CGRect) -> Range<Int> {
        guard offsets.count > 0 else { return 0..<0 }
        let low = firstRow(at: rect.minY)
        var end = low
        while end < offsets.count, snappedFrame(at: end).minY <= rect.maxY { end += 1 }
        return low..<end
    }

    func frame(at index: Int) -> CGRect? {
        index >= 0 && index < offsets.count ? snappedFrame(at: index) : nil
    }
}
#endif
