#if os(iOS)
import CmuxMobileMarkdown
import Observation
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
        guard let known = measured[item.id] else { return item.estimate }
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

    /// The height a cell measured for this row's current revision at this width, if any:
    /// a cell showing it again needs no SwiftUI sizing pass.
    func knownHeight(of id: String) -> (height: CGFloat, width: CGFloat)? {
        guard let row = index[id], row < items.count, let known = measured[id], known.revision == items[row].revision else { return nil }
        return (known.height, known.width)
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

/// The transcript's collection view: reports each finished layout pass, where the
/// controller places the content against the composer (rows measured in that pass
/// changed the content height).
@MainActor
final class ChatTranscriptCollectionView: UICollectionView {
    var didLayout: (() -> Void)?

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

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        if let known, abs(known.width - attributes.size.width) < 0.5, abs(known.height - attributes.size.height) < 0.5 {
            return attributes
        }
        guard let fitted = attributes.copy() as? UICollectionViewLayoutAttributes else { return attributes }
        let size = contentView.systemLayoutSizeFitting(
            CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        fitted.size = CGSize(width: attributes.size.width, height: max(1, ceil(size.height)))
        return fitted
    }
}

/// Drives the transcript's collection view from the store: rows built per changed turn
/// (`ChatTranscriptBuilder`), a diffable snapshot of stable row ids, and a reconfigure of
/// only the rows whose content changed (the streaming block, a finished tool call).
@MainActor
final class ChatTranscriptList: NSObject, UICollectionViewDelegate {
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
    private var revisions: [String: Int] = [:]
    private var shownIDs: [String] = []
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
        let registration = UICollectionView.CellRegistration<ChatRowCell, String> { [weak lookup] cell, _, id in
            lookup?.configure(cell, id: id)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        super.init()
        layout.followsBottom = { [weak surface] in surface?.following ?? true }
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: ChatTranscriptCollectionView, _: UITraitCollection) in
            self?.layout.forgetHeights()
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
        revisions = [:]
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

    func reload() {
        let turns = store.turns
        let built = builder.build(turns: turns, pendingPermission: store.pendingPermission,
                                  askOpen: store.pendingPermission != nil || store.pendingQuestion != nil,
                                  permissionBarHidden: surface.permissionBarHidden)
        var ids: [String] = []
        var seen: Set<String> = []
        var changed: [String] = []
        var items: [ChatTranscriptLayout.Item] = []
        ids.reserveCapacity(shownIDs.count + 4)
        items.reserveCapacity(shownIDs.count + 4)
        let width = max(collectionView.bounds.width - 40, 100)
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
                    if rows[row.id] != nil { changed.append(row.id) }
                    revisions[row.id, default: 0] += 1
                    rows[row.id] = row
                    if loaded, revisions[row.id] == 1, !store.isReplayed(Self.storeID(row)) { fadeIn.insert(row.id) }
                }
                turnIDs.append(row.id)
                turnItems.append(.init(id: row.id, revision: revisions[row.id] ?? 0, gap: row.gap, estimate: row.estimatedHeight(width: width)))
            }
            shownTurns[turn.turnID] = ShownTurn(generation: turn.generation, ids: turnIDs, items: turnItems)
            ids += turnIDs
            items += turnItems
        }
        layout.trailingGap = ChatTranscriptBuilder.trailingGap(after: built.last?.rows.last)
        if ids.count < rows.count {
            let live = Set(ids)
            rows = rows.filter { live.contains($0.key) }
            revisions = revisions.filter { live.contains($0.key) }
            let turnIDs = Set(turns.map(\.id))
            shownTurns = shownTurns.filter { turnIDs.contains($0.key) }
        }
        applies += 1
        lastReconfigured = changed.count
        let anchor = surface.following || !loaded ? nil : layout.firstRow(below: collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
        layout.setItems(items)
        if ids != shownIDs {
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            let shown = Set(shownIDs)
            snapshot.reconfigureItems(changed.filter { shown.contains($0) })
            shownIDs = ids
            dataSource.apply(snapshot, animatingDifferences: false)
        } else if !changed.isEmpty {
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(changed)
            dataSource.apply(snapshot, animatingDifferences: false)
        } else {
            layout.invalidateLayout()
        }
        // Rows inserted or resized above a reader scrolled up do not move what they read.
        if let anchor, let top = layout.top(of: anchor.id), abs(top - anchor.top) > 0.5 {
            collectionView.contentOffset.y += top - anchor.top
        }
        loaded = true
    }

    /// The id the store marks replayed for this row (`TurnRow.id`, or the turn's).
    private static func storeID(_ row: ChatRow) -> String {
        if case .block = row.kind, let hash = row.id.firstIndex(of: "#") { return String(row.id[..<hash]) }
        if row.id.hasPrefix("u-") { return row.turnID }
        return row.id
    }
}

/// The rows by id and their environment, read by the cell registration.
@MainActor
final class ChatRowLookup {
    var rows: [String: ChatRow] = [:]
    var context: ChatRowContext
    weak var layout: ChatTranscriptLayout?

    init(context: ChatRowContext) {
        self.context = context
    }

    func configure(_ cell: ChatRowCell, id: String) {
        guard let row = rows[id] else { return }
        cell.known = layout?.knownHeight(of: id)
        let context = context
        cell.contentConfiguration = UIHostingConfiguration {
            ChatRowView(row: row, context: context)
                // A reused cell never carries another row's state.
                .id(row.id)
        }
        .margins(.horizontal, 20)
        .margins(.vertical, 0)
    }
}

extension ChatRow {
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
