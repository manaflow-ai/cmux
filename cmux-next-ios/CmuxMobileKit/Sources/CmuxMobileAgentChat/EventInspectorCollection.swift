#if os(iOS)
import Observation
import SwiftUI
import UIKit

/// The Event Inspector's rows on a UIKit list (the inset grouped list SwiftUI's `List` draws,
/// with the same row and header): a keystroke's landing or a frame of records is one diffable
/// apply of the rows that changed, and a row's height is measured once (by record, width and
/// text size), not on every update. SwiftUI's List diffed every row and sized every new cell
/// through a hosting view on each update (#47189 r3: events-filter, the burst at the top).
@MainActor
final class EventInspectorCollection: NSObject, UICollectionViewDelegate {
    let collectionView: UICollectionView
    private let dataSource: UICollectionViewDiffableDataSource<Int, Int>
    private var events: [Int: AgentInspectorEvent] = [:]
    private var shownIDs: [Int] = []
    private var summary = ""
    private var header: UICollectionViewListCell?
    /// Heights measured by a cell, per record, at a width and text size.
    private var heights: [Int: CGFloat] = [:]
    private var measuredAt: (width: CGFloat, category: UIContentSizeCategory)?
    /// Opens a record's detail.
    var open: @MainActor (AgentInspectorEvent) -> Void = { _ in }
    /// The reader left the top (`true`) or came back to it.
    var away: @MainActor (Bool) -> Void = { _ in }
    private var isAway = false

    // Tests: the work an update costs.
    /// Snapshot applies.
    private(set) var applies = 0
    /// The record ids the last apply inserted, removed or redrew.
    private(set) var lastChanged: Set<Int> = []
    /// Cells measured (a height the cache did not have).
    private(set) var sizingPasses = 0
    #if DEBUG
    /// The hosting test's counters (`renderProbe`).
    var probe: RenderProbe?
    #endif

    override init() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.alwaysBounceVertical = true
        self.collectionView = collectionView
        // The registration's handler reaches the list through this (it is made before `super.init`).
        let owner = Owner()
        let row = UICollectionView.CellRegistration<EventInspectorRowCell, Int> { cell, _, id in owner.list?.configure(cell, id) }
        dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: row, for: indexPath, item: id)
        }
        super.init()
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, _ in
            self?.header = cell
            self?.drawHeader(cell)
        }
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        owner.list = self
        collectionView.delegate = self
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private final class Owner {
        weak var list: EventInspectorCollection?
    }

    /// The rows newest first and the header's text: one apply of what changed.
    func show(_ rows: [AgentInspectorEvent], summary: String) {
        if summary != self.summary {
            self.summary = summary
            if let header { drawHeader(header) }
        }
        let ids = rows.map(\.id)
        var redraw: [Int] = []
        var next: [Int: AgentInspectorEvent] = [:]
        next.reserveCapacity(rows.count)
        for event in rows {
            if let old = events[event.id], old != event { redraw.append(event.id) }
            next[event.id] = event
        }
        events = next
        guard ids != shownIDs || !redraw.isEmpty else { return }
        let before = Set(shownIDs)
        let after = Set(ids)
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let kept = redraw.filter(before.contains)
        if !kept.isEmpty { snapshot.reconfigureItems(kept) }
        lastChanged = before.symmetricDifference(after).union(kept)
        shownIDs = ids
        applies += 1
        #if DEBUG
        probe?.inspectorApplies += 1
        probe?.inspectorLastChanged = lastChanged.count
        #endif
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The row of record `id` at the top (the pill's jump to the newest).
    func scroll(to id: Int, animated: Bool = true) {
        guard let indexPath = dataSource.indexPath(for: id) else { return }
        collectionView.scrollToItem(at: indexPath, at: .top, animated: animated)
    }

    // MARK: Cells

    private func configure(_ cell: EventInspectorRowCell, _ id: Int) {
        guard let event = events[id] else { return }
        cell.contentConfiguration = UIHostingConfiguration {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.subheadline.monospaced()).lineLimit(2)
                Text(Self.meta(event)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        cell.accessories = [.disclosureIndicator()]
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "\(event.title), \(Self.meta(event))"
        cell.accessibilityTraits = .button
        cell.accessibilityIdentifier = "chat.inspector.row"
        cell.known = knownHeight(id, width: collectionView.bounds.width)
        cell.measured = { [weak self] height, width in self?.record(id, height, width) }
    }

    static func meta(_ event: AgentInspectorEvent) -> String {
        "\(event.dir) · \(event.kind) · \(event.at.formatted(.dateTime.hour().minute().second()))"
    }

    private func drawHeader(_ cell: UICollectionViewListCell) {
        var content = UIListContentConfiguration.groupedHeader()
        content.text = summary
        cell.contentConfiguration = content
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = summary
        cell.accessibilityTraits = [.staticText, .header]
        cell.accessibilityIdentifier = "chat.inspector.count"
    }

    // MARK: Heights

    /// The record's height at this width and text size, when a cell measured it.
    private func knownHeight(_ id: Int, width: CGFloat) -> CGFloat? {
        guard let measuredAt, measuredAt.width == width,
              measuredAt.category == collectionView.traitCollection.preferredContentSizeCategory else { return nil }
        return heights[id]
    }

    private func record(_ id: Int, _ height: CGFloat, _ width: CGFloat) {
        let category = collectionView.traitCollection.preferredContentSizeCategory
        if measuredAt?.width != width || measuredAt?.category != category {
            // A new width or text size: every height is measured again.
            heights = [:]
            measuredAt = (width, category)
        }
        heights[id] = height
        sizingPasses += 1
        // Records the journal dropped leave the cache with them.
        if heights.count > 2 * max(events.count, 64) { heights = heights.filter { events[$0.key] != nil } }
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let event = events[id] else { return }
        open(event)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let away = scrollView.contentOffset.y + scrollView.adjustedContentInset.top > 24
        guard away != isAway else { return }
        isAway = away
        self.away(away)
    }
}

/// A row cell that takes its height from the cache when it has one (no sizing pass), and
/// reports the height it measured otherwise.
@MainActor
final class EventInspectorRowCell: UICollectionViewListCell {
    var known: CGFloat?
    var measured: ((CGFloat, CGFloat) -> Void)?

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        if let known {
            let fitted = attributes.copy() as! UICollectionViewLayoutAttributes
            fitted.size.height = known
            return fitted
        }
        let fitted = super.preferredLayoutAttributesFitting(attributes)
        measured?(fitted.size.height, attributes.size.width)
        known = fitted.size.height
        return fitted
    }
}

/// The SwiftUI side: the collection in the screen, its rows and header from the memo.
struct EventInspectorCollectionView: UIViewRepresentable {
    let rows: [AgentInspectorEvent]
    let shown: Int
    let total: Int
    let dropped: Int
    let memo: EventInspectorRows
    let open: @MainActor (AgentInspectorEvent) -> Void
    let away: @MainActor (Bool) -> Void
    /// The pill's jump: the record to bring to the top (once).
    let jumpTo: Int?
    let jumped: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(memo: memo) }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.list.collectionView
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        #if DEBUG
        coordinator.list.probe = context.environment.renderProbe
        #endif
        coordinator.list.open = open
        coordinator.list.away = away
        coordinator.counts = (shown, total, dropped)
        coordinator.list.show(rows, summary: coordinator.summary())
        if let jumpTo {
            coordinator.list.scroll(to: jumpTo)
            Task { @MainActor in jumped() }
        }
    }

    @MainActor
    final class Coordinator {
        let list = EventInspectorCollection()
        let memo: EventInspectorRows
        var counts = (shown: 0, total: 0, dropped: 0)

        init(memo: EventInspectorRows) {
            self.memo = memo
            observeFiltering()
        }

        /// "N events", "N of M events", dropped, "Filtering…".
        func summary() -> String {
            var text = counts.shown == counts.total ? String(localized: "\(counts.total) events")
                : String(localized: "\(counts.shown) of \(counts.total) events")
            if counts.dropped > 0 { text += " · " + String(localized: "\(counts.dropped) older dropped") }
            if memo.isFiltering {
                text += " · " + String(localized: "mobile.agentChat.inspector.filtering", defaultValue: "Filtering…", bundle: .module)
            }
            return text
        }

        /// A filter starting or landing redraws the header only (the rows are the memo's).
        private func observeFiltering() {
            withObservationTracking { _ = memo.isFiltering } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.observeFiltering()
                    self.list.show(self.list.currentRows, summary: self.summary())
                }
            }
        }
    }
}

extension EventInspectorCollection {
    /// The rows shown now, newest first.
    var currentRows: [AgentInspectorEvent] { shownIDs.compactMap { events[$0] } }
}
#endif
