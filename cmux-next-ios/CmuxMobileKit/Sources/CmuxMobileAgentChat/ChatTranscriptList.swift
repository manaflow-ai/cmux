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
/// (row id, content revision, width, text size), and estimated until then. Visible rows
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
    }

    private struct Measured {
        var revision: Int
        var width: CGFloat
        var height: CGFloat
    }

    private(set) var items: [Item] = []
    private var heights: [CGFloat] = []
    private var tops: [CGFloat] = []
    private var index: [String: Int] = [:]
    private var measured: [String: Measured] = [:]
    private var dirtyFrom: Int? = 0
    private var width: CGFloat = 0
    private(set) var contentHeight: CGFloat = 0
    /// Space under the last row.
    var trailingGap: CGFloat = 24 { didSet { if trailingGap != oldValue { markDirty(max(items.count - 1, 0)) } } }
    /// The reader follows the newest row: a row above that changes height does not move
    /// what they see (the controller keeps the bottom in place instead).
    var followsBottom: () -> Bool = { true }
    /// Rows measured by a cell (tests and the rig's log).
    private(set) var measurements = 0
    /// Heights drawn now instead of the measured ones: a held disclosure's row while its height
    /// moves on the disclosure's spring (`ChatTranscriptList.beginHold`).
    private var displayed: [String: CGFloat] = [:]
    /// A cell measured a held row (`id`, its height drawn now, the measured one): true when the
    /// list moves it there itself, on the disclosure's spring, so the layout does not jump to it.
    var heldResize: ((String, CGFloat, CGFloat) -> Bool)?

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
        items = new
        if heights.count > new.count { heights.removeSubrange(new.count...) }
        heights.reserveCapacity(new.count)
        for row in first..<new.count {
            let height = height(for: new[row])
            if row < heights.count { heights[row] = height } else { heights.append(height) }
        }
        if idsMoved {
            index = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        markDirty(first)
    }

    private func height(for item: Item) -> CGFloat {
        if let shown = displayed[item.id] { return shown }
        guard !item.exact, let known = measured[item.id] else { return item.estimate }
        return known.width == width || width == 0 ? known.height : item.estimate
    }

    /// Text size changed: every measured height is stale.
    func forgetHeights() {
        measured = [:]
        heights = items.map { displayed[$0.id] ?? $0.estimate }
        markDirty(0)
        invalidateLayout()
    }

    func row(of id: String) -> Int? { index[id] }

    /// Drops heights of rows no longer in the transcript.
    func retainMeasured(_ ids: Set<String>) {
        measured = measured.filter { ids.contains($0.key) }
        displayed = displayed.filter { ids.contains($0.key) }
    }

    /// Draws row `id` at `height` until `clearDisplayed` (the next layout pass places it).
    func setDisplayed(_ id: String, _ height: CGFloat) {
        displayed[id] = height
        guard let row = index[id], row < heights.count, heights[row] != height else { return }
        heights[row] = height
        markDirty(row)
    }

    /// What a cell measured for row `id` now (the held row, measured by the list each frame).
    func recordMeasured(_ id: String, _ height: CGFloat) {
        guard let row = index[id], row < items.count else { return }
        measured[id] = Measured(revision: items[row].revision, width: width, height: height)
    }

    /// Row `id` takes its measured height again.
    func clearDisplayed(_ id: String) {
        guard displayed.removeValue(forKey: id) != nil, let row = index[id], row < items.count, row < heights.count else { return }
        heights[row] = height(for: items[row])
        markDirty(row)
    }

    /// The height a cell measured for this row's current revision at this width, if any:
    /// a cell showing it again needs no SwiftUI sizing pass.
    func knownHeight(of id: String) -> (height: CGFloat, width: CGFloat)? {
        guard let row = index[id], row < items.count, let known = measured[id], known.revision == items[row].revision else { return nil }
        return (known.height, known.width)
    }

    /// A row's top (after its gap) and height, in content coordinates.
    func frame(of id: String) -> (top: CGFloat, height: CGFloat)? {
        prepareIfNeeded()
        guard let row = index[id], row < tops.count, row < heights.count else { return nil }
        return (tops[row], heights[row])
    }

    /// A row's top (after its gap), in content coordinates.
    func top(of id: String) -> CGFloat? {
        prepareIfNeeded()
        return index[id].flatMap { $0 < tops.count ? tops[$0] : nil }
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
        let width = collectionView?.bounds.width ?? 0
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

    override var collectionViewContentSize: CGSize { CGSize(width: width, height: contentHeight) }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != width
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

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        prepareIfNeeded()
        guard indexPath.item < items.count else { return nil }
        return attributes(indexPath.item)
    }

    private func attributes(_ row: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: row, section: 0))
        attributes.frame = CGRect(x: 0, y: tops[row], width: width, height: heights[row])
        return attributes
    }

    // MARK: Self-sizing

    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        let row = preferred.indexPath.item
        guard row < items.count else { return false }
        measurements += 1
        let item = items[row]
        measured[item.id] = Measured(revision: item.revision, width: width, height: preferred.size.height)
        if displayed[item.id] != nil, let heldResize, heldResize(item.id, heights[row], preferred.size.height) { return false }
        return abs(preferred.size.height - heights[row]) > 0.25
    }

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        let row = preferred.indexPath.item
        guard row < items.count, let collectionView else { return context }
        let delta = preferred.size.height - heights[row]
        heights[row] = preferred.size.height
        if displayed[items[row].id] != nil { displayed[items[row].id] = preferred.size.height }
        markDirty(row)
        // A row above what the reader sees grew or shrank: keep what they see in place.
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        if !followsBottom(), row < tops.count, tops[row] + heights[row] - delta <= visibleTop {
            context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
        }
        return context
    }
}

/// The transcript's collection view: reports each finished layout pass, where the
/// controller places the content against the composer (rows measured in that pass
/// changed the content height).
@MainActor
final class ChatTranscriptCollectionView: UICollectionView {
    var didLayout: (() -> Void)?

    /// Content insets are manual; the system top edge effect needs the same top
    /// boundary even when the workspace host consumes the UIKit safe area.
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
    /// The row's height measured before at a width (set when configured).
    var known: (height: CGFloat, width: CGFloat)?
    #if DEBUG
    var costKind = "?"
    #endif
    /// The row's disclosure opens or closes under its held line (`ChatTranscriptList.beginHold`):
    /// the cell's frame moves on the disclosure's spring and clips what it draws to that edge,
    /// while the content keeps its own height from the cell's top (the body revealed by the
    /// growing edge, or drawn closing under the shrinking one). Rows below never draw over it.
    var folding = false {
        didSet {
            guard folding != oldValue else { return }
            clipsToBounds = folding
            if folding { known = nil }
            setNeedsLayout()
        }
    }
    /// The content's room while folding: taller than any disclosure's body, so SwiftUI places
    /// the row at the top (`foldableRow`) instead of centering it in the moving frame.
    static let foldContentHeight: CGFloat = 4096

    override func layoutSubviews() {
        super.layoutSubviews()
        guard folding else { return }
        let room = CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, Self.foldContentHeight))
        if contentView.frame != room { contentView.frame = room }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        folding = false
    }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        if let known, abs(known.width - attributes.size.width) < 0.5, abs(known.height - attributes.size.height) < 0.5 {
            return attributes
        }
        guard let fitted = attributes.copy() as? UICollectionViewLayoutAttributes else { return attributes }
        #if DEBUG
        let start = CACurrentMediaTime()
        defer { ChatRowCost.add(costKind, "measure", CACurrentMediaTime() - start) }
        #endif
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        fitted.size = CGSize(width: attributes.size.width, height: max(1, ceil(size.height)))
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
        wireFold(lookup.context)
        layout.heldResize = { [weak self] id, drawn, measured in self?.heldRowMeasured(id, drawn: drawn, measured: measured) ?? false }
        collectionView.prefetchDataSource = self
        layout.followsBottom = { [weak surface] in surface?.following ?? true }
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
        cancelHold()
        self.store = store
        lookup.context = ChatRowContext(store: store, surface: surface)
        wireFold(lookup.context)
        builder = ChatTranscriptBuilder(diffs: store.diffs)
        rows = [:]
        revisions.removeAll()
        lookup.layouts.reset()
        lookup.shownNative = [:]
        lookup.shownPool = [:]
        lookup.markedRow = nil
        primed = false
        shownIDs = []
        shownTurns = [:]
        fadeIn = []
        loaded = false
        observe()
        reload()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard !fadeIn.isEmpty, let id = dataSource.itemIdentifier(for: indexPath), fadeIn.remove(id) != nil,
              !UIAccessibility.isReduceMotionEnabled else { return }
        cell.contentView.alpha = 0
        // motion: allow a 0.15 s fade of a newly arrived row; Reduce Motion skips it.
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { cell.contentView.alpha = 1 }
    }

    /// Find in Chat: the frame (content coordinates) of the row that draws Find block `key`.
    func findFrame(_ key: String) -> (top: CGFloat, height: CGFloat)? {
        guard let id = ChatRow.rowID(forFindKey: key) else { return nil }
        return layout.frame(of: id)
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

    private func environmentChanged() {
        let width = collectionView.bounds.width - 40
        guard width > 0 else { return }
        let environment = ChatNativeEnvironment(width: width, category: collectionView.traitCollection.preferredContentSizeCategory,
                                                wrapCode: CmuxMobilePreferences.wrapCode())
        guard environment != lookup.layouts.environment else { return }
        lookup.layouts.environment = environment
        shownTurns = [:]
        forced.formUnion(shownIDs.filter { lookup.isNativeCandidate($0) })
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
            _ = store.retryRequested
            _ = store.hasEarlierHistory
            // Find in Chat's current match: its row is drawn marked.
            _ = surface.find?.currentBlock
            _ = DiffViewedStore.shared.isViewed(Self.viewedProbe)
        } onChange: { [weak self] in
            // Called before the change lands: rebuild once it has, later in this turn.
            Task { @MainActor [weak self] in
                guard let self, self.store === store else { return }
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
                forced.formUnion(lookup.shownNative.keys)
            }
            shownDisclosures = disclosures
        }
        // Edited-files cards on screen whose viewed marks changed (a file marked in Changes).
        for (id, native) in lookup.shownNative where native {
            guard let row = rows[id], case .editedFiles(let changes) = row.kind else { continue }
            if lookup.viewedShown[id] != ChatNativeRowActions.viewed(changes) { forced.insert(id) }
        }
        // Find in Chat's current match moved: the rows it left and reached are drawn again
        // (the marked one as SwiftUI, with its mark).
        let marked = surface.find?.currentBlock.flatMap(ChatRow.rowID(forFindKey:))
        if marked != lookup.markedRow {
            for id in [lookup.markedRow, marked].compactMap({ $0 }) {
                if let row = rows[id] { shownTurns[row.turnID] = nil }
                forced.insert(id)
            }
            lookup.markedRow = marked
        }
        let turns = store.turns
        let built = builder.build(turns: turns, pendingPermission: store.pendingPermission,
                                  askOpen: store.pendingPermission != nil || store.pendingQuestion != nil,
                                  permissionBarHidden: surface.permissionBarHidden,
                                  earlierHistory: store.hasEarlierHistory, retryPending: store.retryRequested)
        var ids: [String] = []
        var seen: Set<String> = []
        var changed: [String] = []
        var items: [ChatTranscriptLayout.Item] = []
        ids.reserveCapacity(shownIDs.count + 4)
        items.reserveCapacity(shownIDs.count + 4)
        let width = max(collectionView.bounds.width - 40, 100)
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
                turnItems.append(.init(id: row.id, revision: revision, gap: row.gap, estimate: estimate, exact: exact))
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
        // A held disclosure's line is the anchor: rows above it that change do not move it.
        let anchor: (id: String, top: CGFloat)? = if let held = lookup.heldRow, let top = layout.top(of: held) {
            (held, top)
        } else if surface.following || !loaded {
            nil
        } else {
            layout.firstRow(below: collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
        }
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
        // The held row's disclosure changed: its cell measures its SwiftUI content again (the
        // change lands as the height the spring moves to).
        if let held = lookup.heldRow { hostedCell(held)?.invalidateIntrinsicContentSize() }
        loaded = true
        if !missing.isEmpty { prepare(missing, urgent: false) }
        queueWarmUp(ids)
    }

    // MARK: Disclosure hold

    /// A tapped row asks for its line to be held (`ChatTranscriptController.holdForDisclosure(row:)`),
    /// and lets go when its animation completes (`ChatTranscriptController.endFoldHold`).
    var holdRequested: ((String) -> Void)?
    var releaseRequested: (() -> Void)?
    /// Reduce Motion: a held row takes its new height at once (the controller's seam).
    var reducesMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    /// The held row's height moving on the disclosure's spring.
    private var fold: ChatFoldSpring?
    private var foldLink: CADisplayLink?
    /// The hold ended while the row's height still moves: it lets go when that lands.
    private var releasePending = false
    /// The held row's height is moving (the controller's offset follows it frame by frame).
    var isFolding: Bool { fold != nil }
    var heldRow: String? { lookup.heldRow }

    private func wireFold(_ context: ChatRowContext) {
        context.beginFold = { [weak self] id in self?.holdRequested?(id) }
        context.endFold = { [weak self] in self?.releaseRequested?() }
    }

    /// Holds row `id`'s line while its disclosure opens or closes. The row is drawn by its SwiftUI
    /// view for the whole change (a native line is swapped for it, drawn closed, before the change
    /// lands, so its body opens with `DisclosureReveal`), keeps its top (the reload anchor), and its
    /// height moves to what its cell measures on the disclosure's spring: the rows below move with
    /// its growing edge and the cell clips its body to that edge (`ChatRowCell.folding`).
    func beginHold(_ id: String) {
        // Another row's hold hands over to this one (the controller keeps holding).
        if let held = lookup.heldRow, held != id {
            onRelease = nil
            finishHold()
        }
        onRelease = nil
        releasePending = false
        guard rows[id] != nil else { return }
        if lookup.heldRow != id {
            lookup.heldRow = id
            if let frame = layout.frame(of: id) { layout.setDisplayed(id, frame.height) }
        }
        if lookup.shownPool[id]?.hasPrefix("N:") == true {
            if let row = rows[id] { shownTurns[row.turnID] = nil }
            forced.insert(id)
            reload()
            // The SwiftUI row draws its closed state now, so the change that follows animates.
            collectionView.layoutIfNeeded()
        }
        hostedCell(id)?.folding = true
        startFoldLink()
    }

    /// The hold ended. `now` (a drag, a jump, a store swap): the row lands at once. Otherwise it
    /// lets go once its height has landed, never from inside the animation's completion (a SwiftUI
    /// update): the display link's next frames. `released` runs when the row has let go.
    func endHold(now: Bool, released: @escaping () -> Void) {
        guard lookup.heldRow != nil else {
            released()
            return
        }
        onRelease = released
        if now {
            finishHold()
            return
        }
        releasePending = true
        startFoldLink()
    }
    private var onRelease: (() -> Void)?
    /// Heights closer than this are the same while a row is held.
    static let foldTolerance: CGFloat = 1
    /// The held row's height changed outside the spring (Reduce Motion): lay it out next frame.
    private var foldDirty = false

    /// The row takes its measured height and its resting cell again (a closed tool row or group
    /// goes back to its native line).
    private func finishHold() {
        guard let id = lookup.heldRow else { return }
        if let fold, fold.id == id { layout.setDisplayed(id, fold.target) }
        stopFold()
        // What the row measures now is what it rests at (and what a reused cell is sized by).
        if let fitted = measureHeld(id) { layout.recordMeasured(id, fitted) }
        releasePending = false
        lookup.heldRow = nil
        hostedCell(id)?.folding = false
        layout.clearDisplayed(id)
        if let row = rows[id] { shownTurns[row.turnID] = nil }
        forced.insert(id)
        UIView.performWithoutAnimation {
            reload()
            collectionView.layoutIfNeeded()
        }
        let released = onRelease
        onRelease = nil
        released?()
    }

    /// The tab's session was replaced: nothing is held any more.
    private func cancelHold() {
        stopFold()
        releasePending = false
        onRelease = nil
        if let id = lookup.heldRow { layout.clearDisplayed(id) }
        lookup.heldRow = nil
    }

    /// A cell measured the held row: its height moves there on the disclosure's spring (Reduce
    /// Motion: at once, through the layout's own path).
    private func heldRowMeasured(_ id: String, drawn: CGFloat, measured: CGFloat) -> Bool {
        guard id == lookup.heldRow else { return false }
        if reducesMotion() {
            guard abs(drawn - measured) >= Self.foldTolerance else { return true }
            // At once, with no implicit animation (a collection view animates a cell's own
            // self-sizing change): laid out on the display link's next frame.
            layout.setDisplayed(id, measured)
            foldDirty = true
            startFoldLink()
            return true
        }
        let now = CACurrentMediaTime()
        // Under a point is the same height: the cell's own sizing and `measureHeld` round apart
        // by a fraction, and a spring retargeted every frame never lands.
        if let fold, fold.id == id {
            if abs(fold.target - measured) >= Self.foldTolerance { fold.retarget(to: measured, at: now) }
        } else if abs(drawn - measured) >= Self.foldTolerance {
            fold = ChatFoldSpring(id: id, from: drawn, to: measured, at: now)
        }
        startFoldLink()
        return true
    }

    /// The held row's SwiftUI content measured at the cell's width, as the cell sizes itself
    /// (`ChatRowCell.preferredLayoutAttributesFitting`).
    private func measureHeld(_ id: String) -> CGFloat? {
        guard let cell = hostedCell(id), cell.bounds.width > 0 else { return nil }
        let size = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: cell.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let scale = collectionView.traitCollection.displayScale > 0 ? collectionView.traitCollection.displayScale : 3
        return max(1, (size.height * scale).rounded(.up) / scale)
    }

    /// Runs `foldFrame` every display frame while a row is held or its height moves.
    private func startFoldLink() {
        guard foldLink == nil else { return }
        let link = CADisplayLink(target: FoldLinkTarget(self), selector: #selector(FoldLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        foldLink = link
    }

    /// One display frame of a hold. The held row is measured (its SwiftUI content changes on
    /// the disclosure's animation; a cell does not always size itself again when it does) and its
    /// height moves on the disclosure's spring: its height, the rows below and the content size
    /// move together (the controller keeps the offset in range in the same pass).
    fileprivate func foldFrame(_ link: CADisplayLink) {
        var moved = foldDirty
        foldDirty = false
        if let held = lookup.heldRow, let fitted = measureHeld(held) {
            let drawn = layout.frame(of: held)?.height ?? fitted
            let goal = fold.map { $0.id == held ? $0.target : drawn } ?? drawn
            if abs(fitted - goal) >= Self.foldTolerance {
                layout.recordMeasured(held, fitted)
                if reducesMotion() {
                    layout.setDisplayed(held, fitted)
                    moved = true
                } else {
                    _ = heldRowMeasured(held, drawn: drawn, measured: fitted)
                }
            }
        }
        if let fold {
            let (height, done) = fold.sample(at: link.targetTimestamp)
            layout.setDisplayed(fold.id, height)
            moved = true
            if done { self.fold = nil }
        }
        if moved {
            // The spring is the motion: no implicit animation on top of it.
            UIView.performWithoutAnimation {
                layout.invalidateLayout()
                collectionView.layoutIfNeeded()
            }
        }
        guard fold == nil else { return }
        if releasePending {
            finishHold()
        } else if lookup.heldRow == nil {
            stopFold()
        }
    }

    private func stopFold() {
        fold = nil
        foldLink?.invalidate()
        foldLink = nil
    }

    private func hostedCell(_ id: String) -> ChatRowCell? {
        guard let path = dataSource.indexPath(for: id) else { return nil }
        return collectionView.cellForItem(at: path) as? ChatRowCell
    }

    #if DEBUG
    /// The list rig's disclosure (`CMUX_MOBILE_LIST_TOGGLE=1`): the tool row or group whose line is
    /// nearest content y `y` among the rows on screen, and its disclosure key.
    func demoDisclosure(nearContentY y: CGFloat) -> (id: String, key: String)? {
        var best: (id: String, key: String, distance: CGFloat)?
        for path in collectionView.indexPathsForVisibleItems {
            guard let id = dataSource.itemIdentifier(for: path), let row = rows[id], let top = layout.top(of: id) else { continue }
            let key: String
            switch row.kind {
            case .tool(let call): key = "tool-\(call.id)"
            case .toolGroup(let calls, _): key = "group-\(calls.first?.id ?? "")"
            default: continue
            }
            let distance = abs(top - y)
            if distance < best?.distance ?? .infinity { best = (id, key, distance) }
        }
        return best.map { ($0.id, $0.key) }
    }

    /// Row `id`'s frame in content coordinates (the rig's log, tests).
    func rowFrame(_ id: String) -> (top: CGFloat, height: CGFloat)? { layout.frame(of: id) }

    /// The cell drawing row `id` (tests).
    func cell(for id: String) -> UICollectionViewCell? {
        dataSource.indexPath(for: id).flatMap { collectionView.cellForItem(at: $0) }
    }
    #endif

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
                    let width = self.collectionView.bounds.width
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

    /// The id the store marks replayed for this row (`TurnRow.id`, or the turn's).
    private static func storeID(_ row: ChatRow) -> String {
        if case .block = row.kind, let hash = row.id.firstIndex(of: "#") { return String(row.id[..<hash]) }
        if row.id.hasPrefix("u-") { return row.turnID }
        return row.id
    }
}

/// A held disclosure row's height on `Animation.cmuxMobileSmooth`'s spring (0.35 s, no bounce),
/// the spring the body's `DisclosureReveal` plays on, so the cell's edge and the body's reveal
/// move together. A new measurement mid-way retargets it from where it is, with its velocity.
@MainActor
final class ChatFoldSpring {
    static let spring = Spring(duration: 0.35, bounce: 0)
    let id: String
    private(set) var target: CGFloat
    private var from: CGFloat
    private var velocity: CGFloat = 0
    private var start: CFTimeInterval
    private var settle: TimeInterval

    init(id: String, from: CGFloat, to: CGFloat, at time: CFTimeInterval) {
        self.id = id
        self.from = from
        target = to
        start = time
        settle = Self.spring.settlingDuration(target: to - from, initialVelocity: 0, epsilon: 0.1)
    }

    /// The height at `time`, and whether it has landed.
    func sample(at time: CFTimeInterval) -> (CGFloat, Bool) {
        let t = max(0, time - start)
        guard t < settle else { return (target, true) }
        return (from + Self.spring.value(target: target - from, initialVelocity: velocity, time: t), false)
    }

    func retarget(to new: CGFloat, at time: CFTimeInterval) {
        let t = max(0, time - start)
        let (current, landed) = sample(at: time)
        let moving = landed ? 0 : Self.spring.velocity(target: target - from, initialVelocity: velocity, time: t)
        from = current
        target = new
        velocity = moving
        start = time
        settle = Self.spring.settlingDuration(target: new - current, initialVelocity: moving, epsilon: 0.1)
    }
}

/// Breaks the display link's retain of the list.
@MainActor
private final class FoldLinkTarget: NSObject {
    weak var owner: ChatTranscriptList?
    init(_ owner: ChatTranscriptList) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.foldFrame(link) }
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
    /// The row holding Find in Chat's current match: SwiftUI, which draws the mark.
    var markedRow: String?
    /// The tapped disclosure's row while its line is held: SwiftUI, whose body opens and closes
    /// on the disclosure's animation (`ChatTranscriptList.beginHold`).
    var heldRow: String?

    /// The pool the data source dequeues `id` from now.
    func pool(for id: String) -> String {
        guard let row = rows[id] else { return "" }
        return isNative(id) ? "N:" + row.nativeReuseKey : "H:" + row.hostedReuseKey
    }
    /// The viewed files each edited-files card was last drawn with.
    var viewedShown: [String: Set<Int>] = [:]

    func expanded(_ id: String) -> Bool {
        guard let row = rows[id] else { return false }
        switch row.kind {
        case .edit(let call, _): return context.surface.disclosures.isOpen("diff-\(call.id)") ?? false
        default: return context.surface.disclosures.isOpen("code-\(id)") ?? false
        }
    }

    func isNativeCandidate(_ id: String) -> Bool { rows[id].map(eligible) ?? false }

    /// Drawn natively: a native kind in its resting state (an open tool row, group or thought
    /// shows its SwiftUI view).
    func eligible(_ row: ChatRow) -> Bool {
        guard row.id != markedRow, row.id != heldRow else { return false }
        let disclosures = context.surface.disclosures
        return ChatNativeEligibility.drawsNatively(row, accessibilitySize: layouts.environment?.category.isAccessibilityCategory ?? false) {
            disclosures.isOpen($0)
        }
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
        guard let row = rows[id], let native = layouts.makeNow(row, revision: revisions[id] ?? 0, expanded: expanded(id)) else { return }
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
        cell.apply(native, actions: actions)
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
        cell.folding = id == heldRow
        #if DEBUG
        let start = CACurrentMediaTime()
        if ChatRowCost.isEnabled { cell.costKind = row.costKind }
        defer { ChatRowCost.add(row.costKind, "config", CACurrentMediaTime() - start) }
        #endif
        let context = context
        let keepsState = row.keepsViewState
        cell.contentConfiguration = UIHostingConfiguration {
            ChatRowView(row: row, context: context)
                // Rows whose views keep their own state (a question's answers, a code card shown in
                // full) start fresh in a reused cell; the rest update in place.
                .id(keepsState ? row.id : "reused")
        }
        .margins(.horizontal, 20)
        .margins(.vertical, 0)
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

    static let hostedReuseKeys = ["prompt", "block", "thought", "tool", "toolGroup", "edit", "plan", "permission", "question",
                                  "subagents", "working", "editedFiles", "stopped", "failed", "actions", "other"]

    /// The SwiftUI reuse pool: one per kind, so a reused cell keeps its view structure.
    var hostedReuseKey: String {
        switch kind {
        case .sessionStart: "other"
        case .prompt: "prompt"
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
        }
    }

    /// Views of this row keep state of their own (`QuestionCard`'s answers, a code card or a
    /// failure's disclosure).
    var keepsViewState: Bool {
        switch kind {
        case .question, .failed, .block: true
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
        }
    }
}
#endif
