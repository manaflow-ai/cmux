#if os(iOS)
import CmuxMobileDesign
import CmuxMobileDiff
import CmuxMobileMarkdown
import Observation
import OSLog
import SwiftUI
import UIKit

/// The transcript's one-column layout: each row's frame is its gap plus the sum of the
/// heights above it. A row's height is known once its cell measured it, kept per
/// (row id, content revision, disclosures, width, text size), and estimated until then. Visible rows
/// are found by binary search, so a frame costs O(visible rows) and a streamed change
/// re-sums only the rows below the one that grew.
@MainActor
final class ChatTranscriptLayout: UICollectionViewLayout {
    struct Item: Equatable {
        var id: String
        var revision: Int
        var gap: CGFloat
        var estimate: CGFloat
        /// The estimate is the row's real height (a native row's layout).
        var exact = false
        /// What the row's disclosures show (`ChatRowLookup.fold`): not part of its content
        /// revision, but a height measured with them closed is not the height with them open.
        var fold = 0
    }

    private struct Measured {
        var revision: Int
        var fold: Int
        var width: CGFloat
        var height: CGFloat
    }

    /// A row's heights per disclosure state (`Item.fold`): closing a row again takes the
    /// height it was measured at closed, at once, instead of an estimate until a cell
    /// measures it again (a jump below the row, and a wrong height on a busy device).
    private struct RowHeights {
        /// Few states per row (each disclosure open or closed): the newest few are kept.
        static let limit = 4
        private(set) var states: [Measured] = []

        func height(fold: Int) -> Measured? { states.last { $0.fold == fold } }

        mutating func record(_ measured: Measured) {
            states.removeAll { $0.fold == measured.fold }
            states.append(measured)
            if states.count > Self.limit { states.removeFirst(states.count - Self.limit) }
        }
    }

    private(set) var items: [Item] = []
    private var heights: [CGFloat] = []
    private var tops: [CGFloat] = []
    private var index: [String: Int] = [:]
    private var measured: [String: RowHeights] = [:]
    private var dirtyFrom: Int? = 0
    private var width: CGFloat = 0
    /// The collection view's width the column was laid out in (the column is `width`).
    private var boundsWidth: CGFloat = 0
    /// The widest the chat's column draws, with its 20 pt margins inside (Text and Width's
    /// Standard width, as the Mac's chat column); nil fills the screen.
    var columnCap: CGFloat? {
        didSet { if columnCap != oldValue { invalidateLayout() } }
    }
    /// The column's width in a collection view `boundsWidth` wide.
    func columnWidth(in boundsWidth: CGFloat) -> CGFloat {
        guard let columnCap else { return boundsWidth }
        return min(boundsWidth, columnCap + 40)
    }
    /// The column's width now (rows lay out at it less their margins).
    var columnWidth: CGFloat { columnWidth(in: collectionView?.bounds.width ?? 0) }
    private(set) var contentHeight: CGFloat = 0
    /// Space under the last row.
    var trailingGap: CGFloat = 24 { didSet { if trailingGap != oldValue { markDirty(max(items.count - 1, 0)) } } }
    /// Whether a cell's measurement of this row can be its height now: false while a disclosure
    /// change that moves this row's disclosures waits for the list's reload (a SwiftUI row reads
    /// its disclosures itself, so its cell may already draw the new state while its layout item is
    /// still the old one's). Other rows' measurements, a streaming answer's growth, are kept.
    var measuresSettle: (Item) -> Bool = { _ in true }
    /// The reader follows the newest row: a row above that changes height does not move
    /// what they see (the controller keeps the bottom in place instead).
    var followsBottom: () -> Bool = { true }
    /// Rows measured by a cell (tests and the rig's log).
    private(set) var measurements = 0

    // MARK: Rows

    /// The rows in order. Heights come from what cells measured for the same revision at
    /// this width; a changed row keeps its last height until its cell measures it again.
    func setItems(_ new: [Item]) {
        var first: Int?
        let common = min(new.count, items.count)
        for row in 0..<common where new[row] != items[row] {
            first = row
            break
        }
        if first == nil, new.count != items.count { first = common }
        guard let first else { return }
        var idsMoved = new.count != items.count
        if !idsMoved {
            for row in first..<new.count where new[row].id != items[row].id {
                idsMoved = true
                break
            }
        }
        let old = items
        items = new
        if heights.count > new.count { heights.removeSubrange(new.count...) }
        heights.reserveCapacity(new.count)
        for row in first..<new.count {
            var height = height(for: new[row])
            // Only the row's disclosures changed: it keeps the height it is laid out at (its cell
            // already draws the new state while it opens on the disclosure's spring) until its cell
            // measures it. Its estimate (a 32 pt line) made the list's reload, a turn after the tap,
            // snap the opening row shut and back. While a fold holds the heights it keeps it even
            // when the new state was measured before, so a second open or close springs too
            // (`layOut` moves it to the measured height inside the spring) instead of snapping.
            if row < old.count, row < heights.count, old[row].id == new[row].id, old[row].revision == new[row].revision,
               old[row].fold != new[row].fold, !new[row].exact,
               holdsHeights || measured[new[row].id]?.height(fold: new[row].fold) == nil {
                // Held although its new state has a height: `layOut` moves it there on the spring,
                // or the hold's end does (a row the spring did not lay out: off screen, native, or
                // changed by something other than a fold toggle while the spring ran).
                if measured[new[row].id]?.height(fold: new[row].fold) != nil { heldStale.insert(new[row].id) }
                height = heights[row]
            }
            if row < heights.count { heights[row] = height } else { heights.append(height) }
        }
        if idsMoved {
            index = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        markDirty(first)
    }

    private func height(for item: Item) -> CGFloat {
        guard !item.exact, let known = measured[item.id]?.height(fold: item.fold) else { return item.estimate }
        return known.width == width || width == 0 ? known.height : item.estimate
    }

    /// Text size changed: every measured height is stale.
    func forgetHeights() {
        measured = [:]
        heights = items.map(\.estimate)
        markDirty(0)
        invalidateLayout()
    }

    func row(of id: String) -> Int? { index[id] }

    /// While set, the rows keep the heights the layout gives them and cells do not size themselves
    /// (`ChatTranscriptList.resizeForFold`: a disclosure change's rows are reloaded at their drawn
    /// heights, then sprung to their measured new ones). A cell sized while its row's height was not
    /// taken still got its new size: it drew at its full new height at once, over rows that stayed
    /// where they were. Cleared when the spring ends; the cells then measure themselves once.
    var holdsHeights = false {
        didSet {
            guard holdsHeights != oldValue else { return }
            if !holdsHeights { releaseHeldStale() }
            invalidateLayout()
        }
    }

    /// Rows `setItems` kept at their laid-out height under the hold although their new state was
    /// measured, and that `layOut` has not moved yet.
    private var heldStale: Set<String> = []

    private func releaseHeldStale() {
        var first: Int?
        for id in heldStale {
            guard let row = index[id], row < items.count, row < heights.count else { continue }
            heights[row] = height(for: items[row])
            first = min(first ?? row, row)
        }
        heldStale = []
        if let first { markDirty(first) }
    }

    /// Lays row `id` out at `height` (a disclosure's spring, `ChatTranscriptList.resizeForFold`,
    /// measured its cell). Kept only as its laid-out height: its cell's next sizing pass records
    /// the measurement for the row's state. Whether the height changed.
    func layOut(_ id: String, at height: CGFloat) -> Bool {
        heldStale.remove(id)
        guard let row = index[id], row < heights.count, abs(heights[row] - height) > 0.25 else { return false }
        heights[row] = height
        markDirty(row)
        return true
    }

    /// Drops heights of rows no longer in the transcript.
    func retainMeasured(_ ids: Set<String>) {
        measured = measured.filter { ids.contains($0.key) }
    }

    /// The height a cell measured for this row's current revision at this width, if any:
    /// a cell showing it again needs no SwiftUI sizing pass.
    func knownHeight(of id: String) -> (height: CGFloat, width: CGFloat)? {
        guard let row = index[id], row < items.count, let known = measured[id]?.height(fold: items[row].fold),
              known.revision == items[row].revision else { return nil }
        return (known.height, known.width)
    }

    /// A row's top (after its gap), in content coordinates.
    func top(of id: String) -> CGFloat? {
        prepareIfNeeded()
        return index[id].flatMap { $0 < tops.count ? tops[$0] : nil }
    }

    /// A row's height as laid out (measured, else estimated).
    func height(of id: String) -> CGFloat? {
        prepareIfNeeded()
        return index[id].flatMap { $0 < heights.count ? heights[$0] : nil }
    }

    /// The first row whose bottom is below `y`, and its top.
    func firstRow(below y: CGFloat) -> (id: String, top: CGFloat)? {
        prepareIfNeeded()
        let row = firstIndex(bottomAfter: y)
        guard row < items.count else { return nil }
        return (items[row].id, tops[row])
    }

    private func markDirty(_ row: Int) {
        dirtyFrom = min(dirtyFrom ?? row, row)
    }

    // MARK: Layout

    private func prepareIfNeeded() {
        boundsWidth = collectionView?.bounds.width ?? 0
        let width = columnWidth(in: boundsWidth)
        if width != self.width {
            self.width = width
            heights = items.map(height(for:))
            dirtyFrom = 0
        }
        guard let dirty = dirtyFrom else { return }
        dirtyFrom = nil
        let from = min(dirty, items.count, tops.count)
        if tops.count > items.count { tops.removeSubrange(items.count...) }
        var y: CGFloat = from > 0 && from - 1 < tops.count ? tops[from - 1] + heights[from - 1] : 0
        for row in from..<items.count {
            y += items[row].gap
            if row < tops.count { tops[row] = y } else { tops.append(y) }
            y += heights[row]
        }
        contentHeight = items.isEmpty ? 0 : y + trailingGap
    }

    override func prepare() {
        super.prepare()
        prepareIfNeeded()
    }

    override class var layoutAttributesClass: AnyClass { ChatRowAttributes.self }

    /// The revision and disclosures of row `id` as laid out now (its cell is configured with them).
    func shownState(of id: String) -> ChatRowAttributes.Shown? {
        guard let row = index[id], row < items.count else { return nil }
        return .init(revision: items[row].revision, fold: items[row].fold)
    }

    override var collectionViewContentSize: CGSize { CGSize(width: boundsWidth, height: contentHeight) }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != boundsWidth
    }

    private func firstIndex(bottomAfter y: CGFloat) -> Int {
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid] + heights[mid] < y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        prepareIfNeeded()
        var out: [UICollectionViewLayoutAttributes] = []
        var row = firstIndex(bottomAfter: rect.minY)
        while row < items.count, tops[row] <= rect.maxY {
            out.append(attributes(row))
            row += 1
        }
        return out
    }

    /// The rows' tops before a disclosure's spring (`ChatTranscriptList.resizeForFold`), around the
    /// visible rect: where a row coming on screen as a body closes starts from.
    var springFrom: [String: CGFloat] = [:]

    /// A fold spring moves rows off and on screen without changing them. A row pushed off screen
    /// goes to its new place (UIKit left it where it was drawn, fading out: a second copy of the rows
    /// under an opening body), and a row pulled on screen comes from its old one, not faded in.
    override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard holdsHeights, itemIndexPath.item < items.count else { return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath) }
        prepareIfNeeded()
        return attributes(itemIndexPath.item)
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard holdsHeights, itemIndexPath.item < items.count else { return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath) }
        prepareIfNeeded()
        let start = attributes(itemIndexPath.item)
        if let top = springFrom[items[itemIndexPath.item].id] { start.frame.origin.y = top }
        return start
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        prepareIfNeeded()
        guard indexPath.item < items.count else { return nil }
        return attributes(indexPath.item)
    }

    private func attributes(_ row: Int) -> UICollectionViewLayoutAttributes {
        let attributes = ChatRowAttributes(forCellWith: IndexPath(item: row, section: 0))
        // A capped column sits in the middle of a wider screen.
        attributes.frame = CGRect(x: ((boundsWidth - width) / 2).rounded(), y: tops[row], width: width, height: heights[row])
        attributes.held = holdsHeights
        return attributes
    }

    // MARK: Self-sizing

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        let row = preferred.indexPath.item
        guard row < items.count else { return false }
        guard !holdsHeights else { return false }
        let item = items[row]
        measurements += 1
        // Only a measurement of what the row shows now is kept as its height for that state. A
        // cell configured with another state (the layout pass between installing a row's new state
        // and reconfiguring its cell) measured the old state, which was kept for the new one and
        // given to the cell as its known height. While a disclosure change waits for the list's
        // reload, a SwiftUI row may already draw its new state under the old state's item. Either
        // is laid out as drawn, and not kept: the cell's reconfigure, or its content's own change,
        // sizes it again.
        guard let shown = (preferred as? ChatRowAttributes)?.shown, shown.revision == item.revision, shown.fold == item.fold,
              measuresSettle(item) else {
            return abs(preferred.size.height - heights[row]) > 0.25
        }
        measured[item.id, default: RowHeights()].record(Measured(revision: item.revision, fold: item.fold, width: width,
                                                                 height: preferred.size.height))
        return abs(preferred.size.height - heights[row]) > 0.25
    }

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        let row = preferred.indexPath.item
        guard row < items.count, let collectionView else { return context }
        let delta = preferred.size.height - heights[row]
        heights[row] = preferred.size.height
        markDirty(row)
        // A row above what the reader sees grew or shrank: keep what they see in place.
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        if !followsBottom(), row < tops.count, tops[row] + heights[row] - delta <= visibleTop {
            context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
        }
        return context
    }
}

/// A row's layout attributes, and, from its cell's sizing pass, the state the cell drew when it
/// measured (`ChatTranscriptLayout.shouldInvalidateLayout(forPreferredLayoutAttributes:)`).
final class ChatRowAttributes: UICollectionViewLayoutAttributes {
    struct Shown: Equatable {
        var revision: Int
        var fold: Int
    }

    var shown: Shown?
    /// Laid out while a disclosure's spring runs (`ChatTranscriptLayout.holdsHeights`): the cell takes
    /// this size and does not size itself.
    var held = false

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        (copy as? ChatRowAttributes)?.shown = shown
        (copy as? ChatRowAttributes)?.held = held
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ChatRowAttributes, other.shown == shown, other.held == held else { return false }
        return super.isEqual(object)
    }
}

/// The transcript's collection view: reports each finished layout pass, where the
/// controller places the content against the composer (rows measured in that pass
/// changed the content height).
@MainActor
final class ChatTranscriptCollectionView: UICollectionView {
    var didLayout: (() -> Void)?

    /// Content insets are manual; the system top edge effect needs the same top
    /// boundary as the transcript content, even when the workspace host consumes
    /// the UIKit safe area.
    var edgeTopInset: CGFloat = 0 {
        didSet {
            if edgeTopInset != oldValue { safeAreaInsetsDidChange() }
        }
    }

    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.top = max(insets.top, edgeTopInset)
        return insets
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }
}

/// A transcript row's cell: SwiftUI content (`ChatRowView`) that measures its own height.
@MainActor
final class ChatRowCell: UICollectionViewCell {
    /// The row's revision and disclosures this cell draws (set when configured): what its
    /// measurements are of.
    var shown: ChatRowAttributes.Shown?

    /// A row is never inset by the window's top or bottom safe area. A cell under the status bar
    /// (or the transcript's header, which the collection view reports as its top safe area for the
    /// edge effect) passed that inset to its hosted view, which padded itself by it: the row was
    /// measured, and kept, up to 62 pt taller than it draws anywhere else. The side insets stay:
    /// in landscape they keep a row's text clear of the sensor housing.
    override var safeAreaInsets: UIEdgeInsets {
        let insets = super.safeAreaInsets
        return UIEdgeInsets(top: 0, left: insets.left, bottom: 0, right: insets.right)
    }

    /// The row's height measured before at a width for what it shows now (set when configured).
    /// It stands in for the first sizing pass after a configure only: a later pass comes from the
    /// content itself changing size, which is measured.
    var known: (height: CGFloat, width: CGFloat)?
    #if DEBUG
    var costKind = "?"
    #endif

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        if (attributes as? ChatRowAttributes)?.held == true { return attributes }
        if let known {
            self.known = nil
            if abs(known.width - attributes.size.width) < 0.5, abs(known.height - attributes.size.height) < 0.5 { return attributes }
        }
        // The hosted view applies a new configuration, and a disclosure change its views read
        // themselves, in its own layout pass. Measured before it (the sizing pass right after a
        // reconfigure), it reported its old or a half-applied drawing, which was kept as the
        // row's height for the new state; its later update did not always size the cell again.
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        guard let fitted = attributes.copy() as? UICollectionViewLayoutAttributes else { return attributes }
        #if DEBUG
        let start = CACurrentMediaTime()
        defer { ChatRowCost.add(costKind, "measure", CACurrentMediaTime() - start) }
        #endif
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        fitted.size = CGSize(width: attributes.size.width, height: max(1, ceil(size.height)))
        (fitted as? ChatRowAttributes)?.shown = shown
        return fitted
    }
}

#if DEBUG
/// `CMUX_MOBILE_CHAT_AXLOG=1`: the accessibility tree of the first native cell of each kind,
/// logged for the list rig (a check that does not need VoiceOver running).
@MainActor
enum ChatAccessibilityLog {
    static let isEnabled = ProcessInfo.processInfo.environment["CMUX_MOBILE_CHAT_AXLOG"] == "1"
    private static var logged: Set<String> = []

    static func log(kind: String, cell: ChatNativeRowCell) {
        guard isEnabled, logged.insert(kind).inserted else { return }
        Logger(subsystem: "dev.cmux.mobile", category: "frames").notice("FRAMELOG list-stress axtree \(kind, privacy: .public): \(cell.accessibilityDescription(), privacy: .public)")
    }
}

/// `CMUX_MOBILE_CHAT_ROWCOST=1`: main-thread time per transcript row kind (measure, layout,
/// configure), logged every 300 samples for the list rig.
@MainActor
enum ChatRowCost {
    static let isEnabled = ProcessInfo.processInfo.environment["CMUX_MOBILE_CHAT_ROWCOST"] == "1"
    private static var totals: [String: (count: Int, total: Double, max: Double)] = [:]
    private static var samples = 0

    static func add(_ kind: @autoclosure () -> String, _ phase: String, _ seconds: Double) {
        guard isEnabled else { return }
        let key = "\(kind()).\(phase)"
        var entry = totals[key] ?? (0, 0, 0)
        entry.count += 1
        entry.total += seconds * 1000
        entry.max = max(entry.max, seconds * 1000)
        totals[key] = entry
        samples += 1
        guard samples % 300 == 0 else { return }
        let line = totals.sorted { $0.value.total > $1.value.total }.prefix(24)
            .map { String(format: "%@ n=%d tot=%.0f avg=%.2f max=%.1f", $0.key, $0.value.count, $0.value.total, $0.value.total / Double($0.value.count), $0.value.max) }
            .joined(separator: " | ")
        Logger(subsystem: "dev.cmux.mobile", category: "frames").notice("FRAMELOG list-stress rowcost \(line, privacy: .public)")
    }
}
#endif

/// Drives the transcript's collection view from the store: rows built per changed turn
/// (`ChatTranscriptBuilder`), a diffable snapshot of stable row ids, and a reconfigure of
/// only the rows whose content changed (the streaming block, a finished tool call).
@MainActor
final class ChatTranscriptList: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    let collectionView: ChatTranscriptCollectionView
    let layout: ChatTranscriptLayout
    private(set) var store: AgentChatStore
    private let surface: AgentChatSurface
    var context: ChatRowContext { lookup.context }
    private var builder: ChatTranscriptBuilder
    private let dataSource: UICollectionViewDiffableDataSource<Int, String>
    /// The rows by id and their environment, for the cells.
    private let lookup: ChatRowLookup
    private var rows: [String: ChatRow] {
        get { lookup.rows }
        set { lookup.rows = newValue }
    }
    private var revisions: ChatRowRevisions {
        get { lookup.revisions }
        set { lookup.revisions = newValue }
    }
    private var shownIDs: [String] = []
    /// Rows to reconfigure on the next reload although their content is the same (a code
    /// card shown in full).
    private var forced: Set<String> = []
    /// The first reload with a width lays out the newest rows on the spot (what opens on screen).
    private var primed = false
    /// Each turn's rows as last shown: its build generation, row ids and layout items.
    private var shownTurns: [String: ShownTurn] = [:]

    private struct ShownTurn {
        var generation: Int
        var ids: [String]
        var items: [ChatTranscriptLayout.Item]
    }
    /// Rows that arrived live (after the replayed history): they fade in when first shown.
    private var fadeIn: Set<String> = []
    private var loaded = false
    /// Applies (tests and the rig's log).
    private(set) var applies = 0
    private(set) var lastReconfigured = 0

    init(store: AgentChatStore, surface: AgentChatSurface) {
        self.store = store
        self.surface = surface
        let lookup = ChatRowLookup(context: ChatRowContext(store: store, surface: surface))
        self.lookup = lookup
        builder = ChatTranscriptBuilder(diffs: store.diffs)
        let layout = ChatTranscriptLayout()
        self.layout = layout
        lookup.layout = layout
        let collectionView = ChatTranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        self.collectionView = collectionView
        // Native rows (markdown blocks, the session line) are UIKit cells laid out off the main
        // thread. The rest keep SwiftUI, in one reuse pool per kind, so a reused cell's SwiftUI
        // tree is updated in place instead of built again.
        let hosted = ChatHostedRegistrations(lookup: lookup)
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [lookup] view, indexPath, id in
            if lookup.isNative(id) { return hosted.dequeueNative(view, indexPath, id) }
            return hosted.dequeue(view, indexPath, id)
        }
        super.init()
        lookup.showAll = { [weak self] id in self?.showAll(id) }
        collectionView.prefetchDataSource = self
        layout.followsBottom = { [weak surface] in surface?.following ?? true }
        layout.measuresSettle = { [weak self] item in self?.measureSettles(item) ?? true }
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: ChatTranscriptCollectionView, _: UITraitCollection) in
            self?.layout.forgetHeights()
            self?.environmentChanged()
        }
        observe()
        reload()
    }

    /// The tab's session was replaced: show the new store's turns.
    func show(store: AgentChatStore) {
        guard store !== self.store else { return }
        self.store = store
        lookup.context = ChatRowContext(store: store, surface: surface)
        builder = ChatTranscriptBuilder(diffs: store.diffs)
        rows = [:]
        revisions.removeAll()
        lookup.layouts.reset()
        lookup.shownNative = [:]
        lookup.shownPool = [:]
        primed = false
        shownIDs = []
        shownTurns = [:]
        fadeIn = []
        loaded = false
        observe()
        reload()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        let shownID = dataSource.itemIdentifier(for: indexPath)
        // The oldest turn shown came into view (the reader scrolled up, or the first page is
        // shorter than the screen): read the page before it. The list keeps the reader's rows
        // in place as it lands (`reload`'s anchor).
        if shownID == "session-start", store.hasEarlierHistory { store.loadEarlier() }
        guard !fadeIn.isEmpty, let id = shownID, fadeIn.remove(id) != nil,
              !UIAccessibility.isReduceMotionEnabled else { return }
        cell.contentView.alpha = 0
        // motion: allow a 0.15 s fade of a newly arrived row; Reduce Motion skips it.
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { cell.contentView.alpha = 1 }
    }

    /// The transcript controller's scroll handling (follow mode, the jump button, the keyboard).
    weak var scrollDelegate: (any UIScrollViewDelegate)?

    func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollDelegate?.scrollViewDidScroll?(scrollView) }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { scrollDelegate?.scrollViewWillBeginDragging?(scrollView) }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        scrollDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        cell.contentView.alpha = 1
    }

    // MARK: Native rows

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let ids = indexPaths.compactMap { dataSource.itemIdentifier(for: $0) }
        prepare(ids, urgent: true)
    }

    /// Lays out off the main thread the native rows among `ids` that have no layout yet.
    private func prepare(_ ids: [String], urgent: Bool) {
        let jobs = ids.compactMap { lookup.job(for: $0) }
        guard !jobs.isEmpty else { return }
        lookup.layouts.prepare(jobs, urgent: urgent) { [weak self] ready in self?.layoutsReady(ready) }
    }

    /// Native layouts landed: their turns' rows take the real heights.
    private func layoutsReady(_ ids: [String]) {
        var turns = Set<String>()
        for id in ids { if let row = rows[id] { turns.insert(row.turnID) } }
        guard !turns.isEmpty else { return }
        for turn in turns { shownTurns[turn] = nil }
        reload()
    }

    /// The controller laid out the transcript's frame (its own layout pass, before the collection
    /// view's): a new width lays the native rows out again. Never from inside the collection
    /// view's `layoutSubviews`, where a snapshot apply would re-enter its layout.
    func boundsMayHaveChanged() {
        environmentChanged()
    }

    /// Text and Width's width: the column's cap (nil: the whole screen).
    func setColumnCap(_ cap: CGFloat?) {
        guard layout.columnCap != cap else { return }
        let width = layout.columnWidth
        layout.columnCap = cap
        // On a screen narrower than the cap the column keeps its width: nothing to measure again.
        guard layout.columnWidth != width else { return }
        layout.forgetHeights()
        environmentChanged()
    }

    private func environmentChanged() {
        let width = layout.columnWidth - 40
        guard width > 0 else { return }
        let environment = ChatNativeEnvironment(width: width, category: collectionView.traitCollection.preferredContentSizeCategory,
                                                wrapCode: CmuxMobilePreferences.wrapCode())
        guard environment != lookup.layouts.environment else { return }
        // Native rows are laid out again for the new environment. Chosen before it is installed
        // (at an accessibility size no row is native any more), and with the rows whose cell type
        // the new environment changes (native to SwiftUI and back), which `reload` reloads.
        let wereNative = shownIDs.filter { lookup.isNativeCandidate($0) }
        lookup.layouts.environment = environment
        shownTurns = [:]
        forced.formUnion(wereNative)
        forced.formUnion(lookup.shownNative.compactMap { id, native in native != lookup.isNativeCandidate(id) ? id : nil })
        reload()
    }

    /// Whether the row is drawn natively (its layout can be made here).
    func canLayOut(_ id: String) -> Bool {
        rows[id].map { lookup.eligible($0) } ?? false
    }

    /// Find in Chat: the row's real height before a scroll to it. A row far from the reader
    /// may still wait for its off-main layout, and a reveal by its estimate lands off the match.
    func layOutNow(_ id: String) {
        guard let row = rows[id], lookup.eligible(row) else { return }
        let revision = revisions[id] ?? 0
        let open = lookup.expanded(id)
        guard !lookup.layouts.has(id, revision: revision, expanded: open) else { return }
        guard lookup.layouts.makeNow(row, revision: revision, expanded: open) != nil else { return }
        shownTurns[row.turnID] = nil
        reload()
    }

    /// "Show all N lines" on a native code card.
    private func showAll(_ id: String) {
        surface.disclosures.set("code-\(id)", true)
        if let row = rows[id] { shownTurns[row.turnID] = nil }
        forced.insert(id)
        reload()
    }

    // MARK: Store changes

    /// Watches what the rows are built from; a change reloads at the end of this turn of the
    /// main queue (the store applies streamed text once per frame, so this is once per frame).
    /// The surface's held refresh last applied.
    private var appliedHeldRefresh = 0

    private func observe() {
        let store = store
        let surface = surface
        withObservationTracking {
            _ = store.turns
            _ = store.pendingPermission?.request.id
            _ = store.pendingQuestion?.id
            _ = surface.permissionBarHidden
            _ = store.diffs.version
            _ = surface.holdsTranscript
            _ = surface.heldRefresh
            _ = surface.disclosures.revision
            _ = surface.find?.currentBlock
            _ = store.hasEarlierHistory
            _ = DiffViewedStore.shared.isViewed(Self.viewedProbe)
        } onChange: { [weak self, weak store, weak surface] in
            // Called before the change lands: rebuild once it has, later in this turn.
            // Weak: the store's and surface's registrars hold this until a change, and a
            // closed chat's never comes.
            Task { @MainActor [weak self, weak store, weak surface] in
                guard let self, let store, let surface, self.store === store else { return }
                self.observe()
                // Held (the page is a card on the tab grid): no reload per token;
                // the release or a held refresh reloads once with what arrived.
                if surface.holdsTranscript, surface.heldRefresh == self.appliedHeldRefresh { return }
                self.appliedHeldRefresh = surface.heldRefresh
                self.reload()
            }
        }
    }

    /// Any file: reading whether it is viewed observes every viewed mark.
    private static let viewedProbe = DiffFile(path: "", status: .modified, lines: [], hasFullContext: false)
    private var shownDisclosures = -1

    func reload() {
        // A disclosure opened or closed, or a file was marked viewed: shown rows may change
        // their cell type or their drawing.
        let disclosures = surface.disclosures.revision
        if disclosures != shownDisclosures {
            if shownDisclosures >= 0 {
                shownTurns = [:]
                // Only the native rows the change redraws: one whose cell type changes (an open tool
                // row is SwiftUI) or whose disclosures changed (`ChatRowLookup.fold`). Reconfiguring
                // every native row on screen redrew the rows below a tapped line too, whose labels
                // draw asynchronously: while the disclosure's spring moved them, each showed its old
                // drawing at its old place for a frame, a doubled answer under an opening tool row.
                for (id, native) in lookup.shownNative {
                    guard let row = rows[id] else { continue }
                    if lookup.eligible(row) != native || layout.shownState(of: id)?.fold != lookup.fold(row) { forced.insert(id) }
                }
            }
            shownDisclosures = disclosures
        }
        // Find in Chat's current match moved: the rows losing and taking the mark draw again.
        let marked = surface.find?.currentBlock.map(Self.rowID(findBlock:))
        if marked != lookup.findMarked {
            for id in [lookup.findMarked, marked].compactMap(\.self) where rows[id] != nil { forced.insert(id) }
            lookup.findMarked = marked
        }
        // Edited-files cards on screen whose viewed marks changed (a file marked in Changes).
        for (id, native) in lookup.shownNative where native {
            guard let row = rows[id], case .editedFiles(let changes) = row.kind else { continue }
            if lookup.viewedShown[id] != ChatNativeRowActions.viewed(changes) { forced.insert(id) }
        }
        let turns = store.turns
        let built = builder.build(turns: turns, pendingPermission: store.pendingPermission,
                                  askOpen: store.pendingPermission != nil || store.pendingQuestion != nil,
                                  permissionBarHidden: surface.permissionBarHidden,
                                  earlierHistory: store.hasEarlierHistory)
        var ids: [String] = []
        var seen: Set<String> = []
        var changed: [String] = []
        var items: [ChatTranscriptLayout.Item] = []
        ids.reserveCapacity(shownIDs.count + 4)
        items.reserveCapacity(shownIDs.count + 4)
        let width = max(layout.columnWidth - 40, 100)
        let wrap = CmuxMobilePreferences.wrapCode()
        if lookup.layouts.environment?.wrapCode != wrap, lookup.layouts.environment != nil {
            environmentChanged()
            return
        }
        // Laid out now, on the main thread: rows the reader sees first (the newest, on open)
        // and the streaming answer's changed block. Everything else is laid out off the main thread.
        let runningTurn = store.isRunning ? turns.last?.id : nil
        var missing: [String] = []
        // The newest rows on the first reload with a width: laid out as their revision is set below.
        var prime = Set<String>()
        if !primed, lookup.layouts.environment != nil {
            primed = true
            for turn in built.reversed() where prime.count < 24 {
                for row in turn.rows.reversed() where prime.count < 24 && lookup.eligible(row) { prime.insert(row.id) }
            }
        }
        for turn in built {
            if let shown = shownTurns[turn.turnID], shown.generation == turn.generation, !shown.ids.contains(where: seen.contains) {
                seen.formUnion(shown.ids)
                ids += shown.ids
                items += shown.items
                continue
            }
            var turnIDs: [String] = []
            var turnItems: [ChatTranscriptLayout.Item] = []
            for var row in turn.rows {
                // Ids are unique by construction; a repeat from a misbehaving source still
                // must not reach the snapshot (a duplicate identifier traps).
                if !seen.insert(row.id).inserted {
                    var n = 2
                    while seen.contains("\(row.id)~\(n)") { n += 1 }
                    row.id = "\(row.id)~\(n)"
                    seen.insert(row.id)
                }
                if rows[row.id] != row {
                    let isNew = rows[row.id] == nil
                    if !isNew { changed.append(row.id) }
                    revisions.bump(row.id)
                    rows[row.id] = row
                    if loaded, isNew, !store.isReplayed(Self.storeID(row)) { fadeIn.insert(row.id) }
                    if loaded, row.turnID == runningTurn, lookup.eligible(row) {
                        lookup.layouts.makeNow(row, revision: revisions[row.id] ?? 0, expanded: lookup.expanded(row.id))
                    }
                }
                if prime.contains(row.id) {
                    lookup.layouts.makeNow(row, revision: revisions[row.id] ?? 0, expanded: lookup.expanded(row.id))
                }
                if forced.remove(row.id) != nil, !changed.contains(row.id) { changed.append(row.id) }
                let revision = revisions[row.id] ?? 0
                var estimate = row.estimatedHeight(width: width)
                var exact = false
                if lookup.eligible(row) {
                    if let native = lookup.layouts.height(row.id, revision: revision, expanded: lookup.expanded(row.id)) {
                        estimate = native
                        exact = true
                    } else if lookup.layouts.environment != nil, !lookup.layouts.has(row.id, revision: revision, expanded: lookup.expanded(row.id)) {
                        missing.append(row.id)
                    }
                }
                turnIDs.append(row.id)
                turnItems.append(.init(id: row.id, revision: revision, gap: row.gap, estimate: estimate, exact: exact,
                                       fold: lookup.fold(row)))
            }
            shownTurns[turn.turnID] = ShownTurn(generation: turn.generation, ids: turnIDs, items: turnItems)
            ids += turnIDs
            items += turnItems
        }
        layout.trailingGap = ChatTranscriptBuilder.trailingGap(after: built.last?.rows.last)
        if ids.count < rows.count {
            let live = Set(ids)
            rows = rows.filter { live.contains($0.key) }
            revisions.retain(live)
            lookup.layouts.retain(live)
            layout.retainMeasured(live)
            lookup.shownNative = lookup.shownNative.filter { live.contains($0.key) }
            lookup.shownPool = lookup.shownPool.filter { live.contains($0.key) }
            let turnIDs = Set(turns.map(\.id))
            shownTurns = shownTurns.filter { turnIDs.contains($0.key) }
        }
        applies += 1
        lastReconfigured = changed.count
        let anchor = surface.following || !loaded ? nil : layout.firstRow(below: collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
        layout.setItems(items)
        // A row whose cell type changes (native and SwiftUI) is reloaded; reconfiguring one
        // must dequeue the same cell type.
        var reconfigure: [String] = []
        var reloadIDs: [String] = []
        if !forced.isEmpty {
            let present = Set(ids)
            let already = Set(changed)
            for id in forced where !already.contains(id) && present.contains(id) { changed.append(id) }
        }
        forced = []
        for id in changed {
            // A reconfigure must dequeue from the cell's own pool: a row whose pool changed (native
            // and SwiftUI, or a streaming block that became a list) is reloaded.
            if let was = lookup.shownPool[id], was != lookup.pool(for: id) { reloadIDs.append(id) } else { reconfigure.append(id) }
        }
        if ids != shownIDs {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            let shown = Set(shownIDs)
            snapshot.reconfigureItems(reconfigure.filter { shown.contains($0) })
            snapshot.reloadItems(reloadIDs.filter { shown.contains($0) })
            shownIDs = ids
            dataSource.apply(snapshot, animatingDifferences: false)
        } else if !changed.isEmpty {
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(reconfigure)
            snapshot.reloadItems(reloadIDs)
            dataSource.apply(snapshot, animatingDifferences: false)
        } else {
            layout.invalidateLayout()
        }
        // Rows inserted or resized above a reader scrolled up do not move what they read.
        if let anchor, let top = layout.top(of: anchor.id), abs(top - anchor.top) > 0.5 {
            collectionView.contentOffset.y += top - anchor.top
        }
        loaded = true
        if !missing.isEmpty { prepare(missing, urgent: false) }
        queueWarmUp(ids)
    }

    /// Applies a disclosure change the list has not reloaded for yet (its observation reloads on
    /// a later turn of the main queue): a held disclosure's line lets go only once its row shows
    /// the change (`ChatTranscriptController.endFoldHold`).
    func reloadIfDisclosuresChanged() {
        guard disclosuresPending else { return }
        reload()
    }

    /// A disclosure changed since the last reload.
    var disclosuresPending: Bool { surface.disclosures.revision != shownDisclosures }

    /// `TranscriptFoldHold.swap`: a tapped disclosure's row shows its SwiftUI view now, in the state
    /// it drew (a native row at rest is swapped for the same row in SwiftUI), with no animation.
    func showSettlingRows() {
        UIView.performWithoutAnimation {
            reloadIfDisclosuresChanged()
            collectionView.layoutIfNeeded()
        }
    }

    /// `TranscriptFoldHold.resize`, right after the disclosure changed inside its SwiftUI animation:
    /// the rows on screen move to their new heights on a UIKit spring of the same curve
    /// (`cmuxMobileSmooth`). The opening row grows (clipped to its bounds, so its body shows from its
    /// top edge down) and the rows below move with its edge.
    ///
    /// The list's reload (which reconfigures the changed row and every native row on screen) runs
    /// first, with no animation and with the rows' heights held (`ChatTranscriptLayout.holdsHeights`),
    /// so it changes what the cells draw but not where. Each row's new height is then measured from
    /// its cell and given to the layout, and the spring lays the rows out at them. Left to the
    /// observation's reload and the cells' self-sizing, both landed while the spring ran: the rows
    /// below cross-faded between two places, and a body whose height resolves in a later SwiftUI pass
    /// (a tool's code card) drew at full height over the rows below at once.
    func resizeForFold() {
        foldSprings += 1
        layout.holdsHeights = true
        UIView.performWithoutAnimation {
            reloadIfDisclosuresChanged()
            collectionView.layoutIfNeeded()
        }
        let cells = collectionView.visibleCells
        // Where the rows around the screen are before the spring (two screens each way).
        let around = collectionView.bounds.insetBy(dx: 0, dy: -2 * collectionView.bounds.height)
        layout.springFrom = Dictionary((layout.layoutAttributesForElements(in: around) ?? []).compactMap { attributes in
            dataSource.itemIdentifier(for: attributes.indexPath).map { ($0, attributes.frame.minY) }
        }, uniquingKeysWith: { first, _ in first })
        var resized = false
        for case let cell as ChatRowCell in cells {
            guard let id = rowID(of: cell) else { continue }
            // The height its cell measured for this state before (a second open or close): the
            // spring ends where the cell's own sizing will put it. A fresh fit can come up short
            // while the body has not resolved yet, and the row would snap when the hold ends.
            if let known = layout.knownHeight(of: id), abs(known.width - cell.bounds.width) < 0.5 {
                if layout.layOut(id, at: known.height) { resized = true }
                continue
            }
            cell.contentView.setNeedsLayout()
            cell.contentView.layoutIfNeeded()
            let size = cell.contentView.systemLayoutSizeFitting(
                CGSize(width: cell.bounds.width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            if layout.layOut(id, at: max(1, ceil(size.height))) { resized = true }
        }
        let clipped = resized ? cells.filter { !$0.clipsToBounds } : []
        for cell in clipped { cell.clipsToBounds = true }
        if resized { layout.invalidateLayout() }
        // A batch update, not a layout pass: a row pushed below the visible rect gets no attributes in a
        // layout pass, so its cell stayed where it was drawn and faded out there (a second copy of the
        // rows under an opening body); a batch update moves every shown cell to its new place.
        UIView.animate(springDuration: 0.35, bounce: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.collectionView.performBatchUpdates(nil)
        } completion: { [weak self] _ in
            for cell in clipped { cell.clipsToBounds = false }
            guard let self else { return }
            self.foldSprings -= 1
            if self.foldSprings == 0 {
                self.layout.springFrom = [:]
                self.layout.holdsHeights = false
            }
        }
    }

    /// Disclosure springs running (`resizeForFold`); the layout holds its heights while any does.
    private var foldSprings = 0

    private func rowID(of cell: UICollectionViewCell) -> String? {
        collectionView.indexPath(for: cell).flatMap { dataSource.itemIdentifier(for: $0) }
    }

    /// Whether a measurement of `item`'s row is of the state its item records
    /// (`ChatTranscriptLayout.measuresSettle`): with no disclosure change pending, or one that
    /// leaves this row's disclosures (`ChatRowLookup.fold`) as its item has them.
    private func measureSettles(_ item: ChatTranscriptLayout.Item) -> Bool {
        guard disclosuresPending, let row = rows[item.id] else { return true }
        return lookup.fold(row) == item.fold
    }

    // MARK: Inspection (tests)

    /// Row `id`'s cell, when it is on screen.
    func cell(for id: String) -> UICollectionViewCell? {
        dataSource.indexPath(for: id).flatMap { collectionView.cellForItem(at: $0) }
    }

    /// The rows whose cells are on screen, top first.
    var visibleRowIDs: [String] {
        collectionView.indexPathsForVisibleItems.sorted().compactMap { dataSource.itemIdentifier(for: $0) }
    }

    func row(_ id: String) -> ChatRow? { rows[id] }

    // MARK: Warm-up

    /// Row kinds whose first draw happened (or was warmed): a kind's first cell made its labels'
    /// GPU text path and glyph caches on the frame it scrolled in (a 250-280 ms frame with the
    /// main thread idle, early in a first scroll). One off-screen cell per kind, drawn while the
    /// list rests, takes that cost before anyone scrolls (as the Feed's warm-up does).
    private var warmedKinds: Set<String> = []
    private var warmQueue: [String] = []
    private var warmScheduled = false
    private lazy var warmCell = ChatNativeRowCell(frame: .zero)
    /// Set once the screen has appeared: warming during the push competes with its frames.
    private var warmUpAllowed = false

    func allowWarmUp() {
        warmUpAllowed = true
        pumpWarmUp()
    }

    private func queueWarmUp(_ ids: [String]) {
        for id in ids where lookup.isNativeCandidate(id) {
            guard let key = lookup.rows[id]?.nativeReuseKey, warmedKinds.insert(key).inserted else { continue }
            warmQueue.append(id)
        }
        pumpWarmUp()
    }

    private func pumpWarmUp() {
        guard warmUpAllowed, !warmScheduled, !warmQueue.isEmpty else { return }
        warmScheduled = true
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.warmScheduled = false
                // Not while the list moves: a warm-up draw is the cost it saves a later frame.
                if self.collectionView.isTracking || self.collectionView.isDecelerating {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(200))
                        self?.pumpWarmUp()
                    }
                    return
                }
                let id = self.warmQueue.removeFirst()
                if self.lookup.rows[id] != nil, self.lookup.isNative(id) {
                    let cell = self.warmCell
                    let width = self.layout.columnWidth
                    cell.frame = CGRect(x: 0, y: 0, width: width, height: max(self.layout.knownHeight(of: id)?.height ?? 120, 44))
                    cell.overrideUserInterfaceStyle = self.collectionView.traitCollection.userInterfaceStyle
                    self.lookup.configureNative(cell, id: id)
                    cell.layoutIfNeeded()
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
                    _ = renderer.image { context in cell.layer.render(in: context.cgContext) }
                }
                self.pumpWarmUp()
            }
        }
    }

    /// The transcript row that draws Find in Chat's block `key` (`AgentChatFind.promptKey`:
    /// the turn's prompt bubble; `AgentChatFind.blockKey`: one block of an answer).
    static func rowID(findBlock key: String) -> String {
        guard let bar = key.lastIndex(of: "|") else { return key }
        let owner = key[..<bar], part = key[key.index(after: bar)...]
        return part == "prompt" ? "u-\(owner)" : "\(owner)#\(part)"
    }

    /// The id the store marks replayed for this row (`TurnRow.id`, or the turn's).
    private static func storeID(_ row: ChatRow) -> String {
        if case .block = row.kind, let hash = row.id.firstIndex(of: "#") { return String(row.id[..<hash]) }
        if row.id.hasPrefix("u-") { return row.turnID }
        return row.id
    }
}

/// One SwiftUI cell registration per row kind (separate reuse pools).
@MainActor
final class ChatHostedRegistrations {
    private var registrations: [String: UICollectionView.CellRegistration<ChatRowCell, String>] = [:]
    private let fallback: UICollectionView.CellRegistration<ChatRowCell, String>
    /// Native cells, one reuse pool per kind: a reused cell already has the views its kind draws.
    private var native: [String: UICollectionView.CellRegistration<ChatNativeRowCell, String>] = [:]
    private let nativeFallback: UICollectionView.CellRegistration<ChatNativeRowCell, String>
    private let lookup: ChatRowLookup

    func dequeueNative(_ view: UICollectionView, _ indexPath: IndexPath, _ id: String) -> UICollectionViewCell {
        let registration = lookup.rows[id].flatMap { native[$0.nativeReuseKey] } ?? nativeFallback
        return view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
    }

    init(lookup: ChatRowLookup) {
        self.lookup = lookup
        nativeFallback = UICollectionView.CellRegistration<ChatNativeRowCell, String> { [weak lookup] cell, _, id in
            lookup?.configureNative(cell, id: id)
        }
        for key in ChatRow.nativeReuseKeys {
            native[key] = UICollectionView.CellRegistration<ChatNativeRowCell, String> { [weak lookup] cell, _, id in
                lookup?.configureNative(cell, id: id)
            }
        }
        fallback = UICollectionView.CellRegistration<ChatRowCell, String> { [weak lookup] cell, _, id in
            lookup?.configure(cell, id: id)
        }
        for key in ChatRow.hostedReuseKeys {
            registrations[key] = UICollectionView.CellRegistration<ChatRowCell, String> { [weak lookup] cell, _, id in
                lookup?.configure(cell, id: id)
            }
        }
    }

    func dequeue(_ view: UICollectionView, _ indexPath: IndexPath, _ id: String) -> UICollectionViewCell {
        let key = lookup.reuseKey(id)
        let registration = registrations[key] ?? fallback
        return view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
    }
}

/// The rows by id and their environment, read by the cell registration.
@MainActor
final class ChatRowLookup {
    var rows: [String: ChatRow] = [:]
    var revisions = ChatRowRevisions()
    var context: ChatRowContext
    weak var layout: ChatTranscriptLayout?
    let layouts = ChatNativeLayouts()
    var showAll: (String) -> Void = { _ in }
    /// The cell type each row was last configured in (true: native).
    var shownNative: [String: Bool] = [:]
    /// The reuse pool each row's cell came from (a reconfigure must use the same one).
    var shownPool: [String: String] = [:]

    /// The pool the data source dequeues `id` from now.
    func pool(for id: String) -> String {
        guard let row = rows[id] else { return "" }
        return isNative(id) ? "N:" + row.nativeReuseKey : "H:" + row.hostedReuseKey
    }
    /// The viewed files each edited-files card was last drawn with.
    var viewedShown: [String: Set<Int>] = [:]
    /// The row holding Find in Chat's current match (`ChatTranscriptList.rowID(findBlock:)`).
    var findMarked: String?

    func expanded(_ id: String) -> Bool {
        guard let row = rows[id] else { return false }
        switch row.kind {
        case .edit(let call, _): return context.surface.disclosures.isOpen("diff-\(call.id)") ?? false
        default: return context.surface.disclosures.isOpen("code-\(id)") ?? false
        }
    }

    func isNativeCandidate(_ id: String) -> Bool { rows[id].map(eligible) ?? false }

    /// The states of the disclosures the row draws (`ChatTranscriptLayout.Item.fold`): a tool row's
    /// output, a group and its calls' outputs, a thought, a long diff or a code card shown in full.
    func fold(_ row: ChatRow) -> Int {
        let disclosures = context.surface.disclosures
        var hasher = Hasher()
        switch row.kind {
        case .tool(let call):
            hasher.combine(disclosures.isOpen("tool-\(call.id)"))
        case .toolGroup(let calls, _):
            hasher.combine(disclosures.isOpen("group-\(calls.first?.id ?? "")"))
            for call in calls { hasher.combine(disclosures.isOpen("tool-\(call.id)")) }
        case .thought:
            hasher.combine(disclosures.isOpen("thought-\(row.id)"))
        case .edit(let call, _):
            // A running edit draws as its tool row.
            hasher.combine(disclosures.isOpen("diff-\(call.id)"))
            hasher.combine(disclosures.isOpen("tool-\(call.id)"))
        default:
            hasher.combine(disclosures.isOpen("code-\(row.id)"))
        }
        return hasher.finalize()
    }

    /// Drawn natively: a native kind in its resting state (an open tool row, group or thought
    /// shows its SwiftUI view).
    func eligible(_ row: ChatRow) -> Bool {
        let disclosures = context.surface.disclosures
        return ChatNativeEligibility.drawsNatively(row, accessibilitySize: layouts.environment?.category.isAccessibilityCategory ?? false,
                                                   wrapCode: layouts.environment?.wrapCode ?? false,
                                                   isOpen: { disclosures.isOpen($0) }, isSettling: { disclosures.isSettling($0) })
    }

    /// A native row has a layout (made now if it has none; math stays SwiftUI).
    func isNative(_ id: String) -> Bool {
        guard let row = rows[id], eligible(row), layouts.environment != nil else { return false }
        return layouts.makeNow(row, revision: revisions[id] ?? 0, expanded: expanded(id)) != nil
    }

    func job(for id: String) -> ChatNativeLayouts.Job? {
        guard let row = rows[id], eligible(row) else { return nil }
        let revision = revisions[id] ?? 0
        let open = expanded(id)
        guard !layouts.has(id, revision: revision, expanded: open) else { return nil }
        return ChatNativeLayouts.Job(id: id, revision: revision, kind: row.kind, expanded: open)
    }

    func reuseKey(_ id: String) -> String { rows[id]?.hostedReuseKey ?? "other" }

    func configureNative(_ cell: ChatNativeRowCell, id: String) {
        // A reused cell measures nothing for this row until it draws it.
        cell.shown = nil
        guard let row = rows[id], let native = layouts.makeNow(row, revision: revisions[id] ?? 0, expanded: expanded(id)) else { return }
        // The layout's width is the cell's less its 20 pt margins (`environmentChanged`).
        cell.layoutWidth = (layouts.environment?.width ?? -40) + 40
        shownNative[id] = true
        shownPool[id] = "N:" + row.nativeReuseKey
        #if DEBUG
        let start = CACurrentMediaTime()
        if ChatRowCost.isEnabled { cell.costKind = row.costKind }
        defer { ChatRowCost.add(row.costKind, "config", CACurrentMediaTime() - start) }
        #endif
        let context = context
        var actions = ChatNativeActions()
        actions.openLink = { url in context.openURL(url) }
        if case .block(let messageID, _) = row.kind { actions.message = { context.messageText(messageID) } }
        let showAll = showAll
        actions.showAll = { showAll(id) }
        ChatNativeRowActions.configure(&actions, row: row, context: context)
        if case .editedFiles(let changes) = row.kind { viewedShown[id] = actions.viewed }
        cell.shown = layout?.shownState(of: id)
        cell.apply(native, actions: actions)
        cell.setFindMarked(id == findMarked)
        #if DEBUG
        ChatAccessibilityLog.log(kind: row.hostedReuseKey == "block" ? row.nativeReuseKey : row.hostedReuseKey, cell: cell)
        #endif
    }

    init(context: ChatRowContext) {
        self.context = context
    }

    func configure(_ cell: ChatRowCell, id: String) {
        guard let row = rows[id] else { return }
        shownNative[id] = false
        shownPool[id] = "H:" + row.hostedReuseKey
        cell.known = layout?.knownHeight(of: id)
        cell.shown = layout?.shownState(of: id)
        cell.setFindMarked(id == findMarked)
        #if DEBUG
        let start = CACurrentMediaTime()
        if ChatRowCost.isEnabled { cell.costKind = row.costKind }
        defer { ChatRowCost.add(row.costKind, "config", CACurrentMediaTime() - start) }
        #endif
        let context = context
        let keepsState = row.keepsViewState
        let marked = id == findMarked
        cell.contentConfiguration = UIHostingConfiguration {
            ChatRowTop {
                ChatRowView(row: row, context: context)

                    // VoiceOver hears which row holds Find in Chat's current match.
                    .accessibilityAddTraits(marked ? .isSelected : [])
                    // Rows whose views keep their own state (a question's answers, a code card shown in
                    // full) start fresh in a reused cell; the rest update in place.
                    .id(keepsState ? row.id : "reused")
            }
        }
        .margins(.horizontal, 20)
        .margins(.vertical, 0)
    }
}

extension UICollectionViewCell {
    /// Find in Chat's mark on the row that holds the current match: a tinted rounded
    /// background reaching 6 pt past the row's 20 pt margins.
    func setFindMarked(_ marked: Bool) {
        var background = UIBackgroundConfiguration.clear()
        if marked {
            background.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.28)
            background.cornerRadius = 12
            background.backgroundInsets = NSDirectionalEdgeInsets(top: -6, leading: 14, bottom: -6, trailing: 14)
        }
        backgroundConfiguration = background
        // VoiceOver hears the current match as selected, as the SwiftUI rows' find marks did.
        // Native rows set their elements' traits on every configure, so this is called after it.
        for case let element as NSObject in accessibilityElements ?? [] where !element.accessibilityTraits.contains(.button) {
            if marked {
                element.accessibilityTraits.insert(.selected)
            } else {
                element.accessibilityTraits.remove(.selected)
            }
        }
    }
}

extension ChatRow {
    /// Drawn by `ChatNativeRowCell` when its block has no math.
    var isNativeCandidate: Bool { ChatNativeEligibility.isCandidate(kind) }

    static let nativeReuseKeys = ["n-code", "n-table", "n-list", "n-text"] + hostedReuseKeys.map { "n-" + $0 }

    /// The native reuse pool.
    var nativeReuseKey: String {
        switch kind {
        case .block(_, let block):
            switch block.kind {
            case .code: "n-code"
            case .table: "n-table"
            case .list: "n-list"
            default: "n-text"
            }
        default: "n-" + hostedReuseKey
        }
    }

    static let hostedReuseKeys = ["prompt", "incoming", "block", "thought", "tool", "toolGroup", "edit", "plan", "permission", "question",
                                  "subagents", "working", "editedFiles", "stopped", "failed", "actions", "nextStep", "other"]

    /// The SwiftUI reuse pool: one per kind, so a reused cell keeps its view structure.
    var hostedReuseKey: String {
        switch kind {
        case .sessionStart: "other"
        case .prompt: "prompt"
        case .incoming: "incoming"
        case .block: "block"
        case .thought: "thought"
        case .tool: "tool"
        case .toolGroup: "toolGroup"
        case .edit: "edit"
        case .plan: "plan"
        case .permission: "permission"
        case .question: "question"
        case .subagents: "subagents"
        case .working: "working"
        case .editedFiles: "editedFiles"
        case .stopped: "stopped"
        case .failed: "failed"
        case .actions: "actions"
        case .nextStep: "nextStep"
        }
    }

    /// Views of this row keep state of their own (`QuestionCard`'s answers, a code card or a
    /// failure's disclosure).
    var keepsViewState: Bool {
        switch kind {
        case .question, .failed, .block, .nextStep: true
        default: false
        }
    }

    #if DEBUG
    var costKind: String {
        switch kind {
        case .block(_, let block):
            switch block.kind {
            case .code: "code"
            case .table: "table"
            case .list: "list"
            case .heading: "heading"
            default: "para"
            }
        default: hostedReuseKey == "other" ? "sessionStart" : hostedReuseKey
        }
    }
    #endif

    /// A guess at the row's height before its cell measures it (rows far from the reader).
    func estimatedHeight(width: CGFloat) -> CGFloat {
        let perLine: CGFloat = 22
        func lines(_ text: String, chars: CGFloat = 8.6) -> CGFloat {
            let perRow = max(width / chars, 10)
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ceil(CGFloat($1.count) / perRow)) }
        }
        switch kind {
        case .sessionStart: return 46
        case .prompt(let text, let attachments, _, _):
            return lines(text) * perLine + 22 + (attachments.isEmpty ? 0 : 156)
        case .incoming(let incoming, _):
            return incoming.messages.count == 1 ? 46 + lines(incoming.text) * perLine : 46 + CGFloat(incoming.messages.count) * 40
        case .block(_, let block):
            switch block.kind {
            case .heading: return 30
            case .paragraph(let text), .quote(let text): return lines(text) * perLine
            case .list(let list): return list.items.reduce(0) { $0 + lines($1.text) * perLine + 8 }
            case .code(_, let code, _): return min(CGFloat(code.split(separator: "\n").count), 14) * 19 + 60
            case .table(let table): return CGFloat(table.rows.count + 1) * 41
            case .math: return 60
            case .rule: return 9
            }
        case .thought, .tool, .toolGroup, .working: return 32
        case .edit(_, let files): return files == nil ? 44 : 44 + 12 * 19 + 20
        case .plan(let entries): return 56 + CGFloat(entries.count) * 30
        case .permission: return 120
        case .question: return 220
        case .subagents(let ids): return 45 + CGFloat(ids.count) * 52
        case .editedFiles(let changes): return 49 + CGFloat(changes.files.count) * 44
        case .stopped: return 18
        case .failed: return 170
        case .actions: return 44
        case .nextStep(let ask, let answer, _): return answer == nil ? 96 + CGFloat(ask.options.count) * 50 : 64
        }
    }
}
/// A row's SwiftUI content, pinned to the top of its cell (2026-11-04, the user: "the row itself
/// shouldn't move and it should only reveal whatever is under it"). The hosting view centered the
/// content in the cell whenever their heights differed, and while a disclosure opens or closes they
/// do: the cell takes its new height on the list's spring while the content's height animates on
/// SwiftUI's. The tapped line slid down and back while it opened, and up out of the clipped cell
/// while it closed. Pinned, the line stays where it is drawn and the cell's edge reveals the body.
/// Sizing (no height proposed) still gets the content's own height.
struct ChatRowTop: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        guard let height = proposal.height, height > 0, height.isFinite else { return content }
        return CGSize(width: proposal.width ?? content.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
#endif
