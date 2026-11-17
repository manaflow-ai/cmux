#if os(iOS)
import SwiftUI
import UIKit

/// One trailing swipe action on a ``PagedList`` row (UIKit's own swipe: slide, full-swipe, haptic).
public struct PagedListAction {
    public var title: String
    public var systemImage: String
    public var tint: Color
    /// The row leaves the list (UIKit slides it out).
    public var removesRow: Bool
    public var handler: @MainActor () -> Void

    public init(_ title: String, systemImage: String, tint: Color, removesRow: Bool = false, handler: @escaping @MainActor () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.removesRow = removesRow
        self.handler = handler
    }
}

/// What a test or a lab learns from a ``PagedList`` as it works (nil in the app).
@MainActor
public final class PagedListProbe {
    /// A page or a live item landed: how far the row the reader was looking at moved on screen (pt),
    /// measured after the layout pass that placed it and the self-sizing that followed.
    public var pageLanded: ((_ shift: CGFloat, _ rows: Int) -> Void)?
    /// The reader started (true) or stopped (false) moving the list.
    public var scrolling: ((Bool) -> Void)?

    public init() {}
}

/// The list's cell ids: one per row, and the paging edge.
enum PagedListCellID<ID: Hashable & Sendable>: Hashable, Sendable {
    case row(ID)
    case edge
}

/// A list layout (UIKit's, for its swipe actions and native scrolling) that keeps what the reader
/// sees in place when a row above them changes height: a row that came in with an estimated height
/// and measured on its way into view, a reconfigure, a text-size change. UIKit's own layout moves
/// the rows under the reader by the difference (the "jump while scrolling up" every chat list has).
final class PagedListLayout: UICollectionViewCompositionalLayout {
    /// Corrections made (tests and the lab).
    private(set) var corrections = 0

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        guard let collectionView, context.contentOffsetAdjustment == .zero else { return context }
        let delta = preferred.frame.height - original.frame.height
        guard abs(delta) > 0.25 else { return context }
        // The row starts above the reader's top edge: everything the reader sees is below it and would
        // move by `delta`. Move the viewport with it.
        let readerTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        guard original.frame.minY < readerTop - 0.5 else { return context }
        context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
        corrections += 1
        return context
    }
}

/// A row's cell: a SwiftUI row (`UIHostingConfiguration`) whose height comes from the list's cache
/// when it was measured before for the same value, width and text size (no SwiftUI sizing pass and
/// no estimate to correct on the way back into view). A plain cell, not a list cell: a list cell
/// asks its hosting view for the separator inset on every layout (WorkspacesCollection measured a
/// third of the main thread in it); swipe actions come from the list layout all the same.
final class PagedListCell: UICollectionViewCell {
    var knownHeight: ((CGFloat) -> CGFloat?)?
    var measured: ((CGFloat, CGFloat) -> Void)?

    override func prepareForReuse() {
        super.prepareForReuse()
        knownHeight = nil
        measured = nil
    }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let width = attributes.size.width
        if let height = knownHeight?(width) {
            let fitted = attributes.copy() as? UICollectionViewLayoutAttributes ?? attributes
            fitted.size = CGSize(width: width, height: height)
            return fitted
        }
        let fitted = super.preferredLayoutAttributesFitting(attributes)
        measured?(width, fitted.size.height)
        return fitted
    }
}

extension UIScrollView {
    /// How many screens of content lie between the viewport and the paging edge: the bottom of a
    /// `.down` list, the top of an `.up` one. Every paged list (``PagedList``, the chat transcript)
    /// asks for its next page by this one measure.
    public func pagedScreensToEdge(_ direction: PagedListDirection) -> CGFloat {
        let screen = bounds.height
        guard screen > 0 else { return .infinity }
        let distance: CGFloat = switch direction {
        case .down: contentSize.height + adjustedContentInset.bottom - (contentOffset.y + screen)
        case .up: contentOffset.y + adjustedContentInset.top
        }
        return max(0, distance) / screen
    }
}

/// The list's swipe provider, set once the controller exists (the layout is made before it).
@MainActor
final class SwipeProvider {
    var provide: ((IndexPath) -> UISwipeActionsConfiguration?)?
}

/// The scroll view: tells its controller about each layout pass, where an `.up` list that follows its
/// newest row stays at the bottom (a keyboard, a rotation, a row that grew) and a short `.up` list
/// sits at the bottom.
final class PagedListCollectionView: UICollectionView {
    var didLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }
}

/// The UIKit side of ``PagedList`` (verify/paged-list.md): a diffable list whose rows are SwiftUI,
/// which reads the next page ahead of the reader, never moves what they read when a page or a live row
/// lands, and keeps an `.up` list on its newest row while the reader is there.
@MainActor
final class PagedListController<Item: Identifiable & Equatable, Row: View>: NSObject, UICollectionViewDelegate where Item.ID: Sendable {
    typealias CellID = PagedListCellID<Item.ID>

    let direction: PagedListDirection
    let collectionView: PagedListCollectionView
    private let layout: PagedListLayout
    private var dataSource: UICollectionViewDiffableDataSource<Int, CellID>!

    var row: (Item) -> Row
    var edgeView: (PagedListEdge) -> AnyView
    var swipeActions: ((Item) -> [PagedListAction])?
    var loadMore: () -> Void = {}
    var probe: PagedListProbe?
    /// Screens ahead of the edge at which the next page is asked for.
    var readAheadScreens: CGFloat = 2
    /// Rows keep their measured height while their value is the same; off for rows whose height
    /// depends on state outside the item.
    var cachesHeights = true

    private var items: [Item.ID: Item] = [:]
    private var order: [Item.ID] = []
    private var edge: PagedListEdge = .end
    private var showsEdge = false
    private var heights: [Item.ID: (width: CGFloat, height: CGFloat)] = [:]
    /// The reader is at the newest end: the top of a `.down` list, the bottom of an `.up` one.
    /// An `.up` list that follows stays at the bottom through every layout pass.
    private(set) var followsNewest = true
    private var loaded = false
    private var lastBoundsHeight: CGFloat = 0
    private var bottomGap: CGFloat = 0
    private var readAheadQueued = false
    private(set) var applies = 0
    private var refreshAction: (() async -> Void)?
    /// Pull to refresh under the search drawer (`ListPullToRefresh` says why not `UIRefreshControl`).
    private var pullToRefresh: ListPullToRefresh?

    init(direction: PagedListDirection, row: @escaping (Item) -> Row, edgeView: @escaping (PagedListEdge) -> AnyView) {
        self.direction = direction
        self.row = row
        self.edgeView = edgeView
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        config.showsSeparators = false
        config.headerMode = .none
        // Trailing only: a rightward swipe from the leading edge belongs to the team sidebar.
        config.leadingSwipeActionsConfigurationProvider = nil
        let swipes = SwipeProvider()
        config.trailingSwipeActionsConfigurationProvider = { indexPath in swipes.provide?(indexPath) }
        let listConfig = config
        layout = PagedListLayout { _, environment in
            NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: environment)
        }
        collectionView = PagedListCollectionView(frame: .zero, collectionViewLayout: layout)
        super.init()
        swipes.provide = { [weak self] indexPath in self?.swipeConfiguration(at: indexPath) }
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.allowsSelection = false
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.delegate = self
        // A tap on the status bar goes to the newest end, which is the bottom of an `.up` list.
        collectionView.scrollsToTop = direction == .down

        let rowCell = UICollectionView.CellRegistration<PagedListCell, Item.ID> { [weak self] cell, _, id in
            self?.configure(cell, id)
        }
        let edgeCell = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            guard let self else { return }
            let view = self.edgeView(self.edge)
            cell.contentConfiguration = UIHostingConfiguration { view }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            switch id {
            case .row(let rowID): view.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: rowID)
            case .edge: view.dequeueConfiguredReusableCell(using: edgeCell, for: indexPath, item: 0)
            }
        }
        collectionView.didLayout = { [weak self] in self?.didLayout() }
        collectionView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: PagedListCollectionView, _: UITraitCollection) in
            self?.textSizeChanged()
        }
    }

    // MARK: Rows

    private func configure(_ cell: PagedListCell, _ id: Item.ID) {
        guard let item = items[id] else { return }
        let row = row
        cell.contentConfiguration = UIHostingConfiguration { row(item) }.margins(.all, 0)
        cell.backgroundConfiguration = .clear()
        guard cachesHeights else { return }
        cell.knownHeight = { [weak self] width in
            guard let known = self?.heights[id], known.width == width else { return nil }
            return known.height
        }
        cell.measured = { [weak self] width, height in self?.heights[id] = (width, height) }
    }

    /// Shows `newItems` (top to bottom) and the edge's state. Rows whose value changed are drawn
    /// again in place; rows that came or went above the reader leave what they read where it was.
    func update(items newItems: [Item], edge newEdge: PagedListEdge) {
        let newOrder = newItems.map(\.id)
        var changed: [CellID] = []
        var next: [Item.ID: Item] = [:]
        next.reserveCapacity(newItems.count)
        for item in newItems {
            if let old = items[item.id], old != item {
                changed.append(.row(item.id))
                heights[item.id] = nil
            }
            next[item.id] = item
        }
        let edgeChanged = newEdge != edge
        let newShowsEdge = newEdge != .end || edgeHasEndView
        edge = newEdge
        guard newOrder != order || newShowsEdge != showsEdge || !changed.isEmpty || edgeChanged || !loaded else { return }
        let rowsChanged = newOrder != order || newShowsEdge != showsEdge
        let anchor = rowsChanged && loaded && !followsNewest ? captureAnchor() : nil
        items = next
        order = newOrder
        showsEdge = newShowsEdge
        if rowsChanged { heights = heights.filter { next[$0.key] != nil } }

        var snapshot = NSDiffableDataSourceSnapshot<Int, CellID>()
        snapshot.appendSections([0])
        var ids = newOrder.map { CellID.row($0) }
        if newShowsEdge {
            if direction == .down { ids.append(.edge) } else { ids.insert(.edge, at: 0) }
        }
        snapshot.appendItems(ids)
        let present = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(changed.filter { present.contains($0) } + (edgeChanged && present.contains(.edge) && newShowsEdge ? [.edge] : []))
        applies += 1
        // No animation: a row slides in nowhere (a page lands out of view, or under a reader who
        // stays put); the diff only reconfigures what changed.
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()
        if let anchor { restore(anchor) }
        if !loaded, direction == .up { scrollToNewest() }
        loaded = true
        if rowsChanged { reportShift(anchor) }
        queueReadAhead()
    }

    /// Whether `.end` shows a row (an end label).
    var edgeHasEndView = false

    // MARK: Keeping the reader in place

    private struct Anchor {
        var id: CellID
        /// The row's top on screen (relative to the viewport's top).
        var screenY: CGFloat
    }

    /// The first row whose bottom is below the reader's top edge.
    private func captureAnchor() -> Anchor? {
        let readerTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        for indexPath in visible {
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                  attributes.frame.maxY > readerTop + 0.5,
                  let id = dataSource.itemIdentifier(for: indexPath), id != .edge else { continue }
            return Anchor(id: id, screenY: attributes.frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    private func screenY(of id: CellID) -> CGFloat? {
        guard let indexPath = dataSource.indexPath(for: id),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
        return attributes.frame.minY - collectionView.contentOffset.y
    }

    private func restore(_ anchor: Anchor) {
        guard let now = screenY(of: anchor.id) else { return }
        let delta = now - anchor.screenY
        guard abs(delta) > 0.25 else { return }
        collectionView.contentOffset.y += delta
    }

    /// Reports how far the anchored row moved, after the run loop turn in which its self-sizing settled.
    private func reportShift(_ anchor: Anchor?) {
        guard let probe else { return }
        let rows = order.count
        guard let anchor else {
            probe.pageLanded?(0, rows)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            let shift = self.screenY(of: anchor.id).map { abs($0 - anchor.screenY) } ?? 0
            probe.pageLanded?(shift, rows)
        }
    }

    private var maxOffsetY: CGFloat {
        max(-collectionView.adjustedContentInset.top,
            collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
    }

    private func scrollToNewest() {
        let target = direction == .up ? maxOffsetY : -collectionView.adjustedContentInset.top
        if abs(collectionView.contentOffset.y - target) > 0.25 { collectionView.contentOffset.y = target }
    }

    /// Each layout pass: a short `.up` list sits at the bottom; an `.up` list that follows its newest
    /// row stays on it (keyboard, rotation, a row that grew); a reader in the middle of an `.up` list
    /// keeps the bottom edge's distance when the list's height changes (Messages does the same).
    private func didLayout() {
        guard direction == .up else { return }
        let height = collectionView.bounds.height
        defer { lastBoundsHeight = height }
        let insets = collectionView.adjustedContentInset
        let room = height - (insets.top - bottomGap) - insets.bottom
        let gap = max(0, (room - collectionView.contentSize.height).rounded(.down))
        if abs(gap - bottomGap) > 0.5 {
            collectionView.contentInset.top += gap - bottomGap
            bottomGap = gap
        }
        guard loaded, !collectionView.isTracking else { return }
        if followsNewest {
            if !collectionView.isDecelerating { scrollToNewest() }
        } else if lastBoundsHeight > 0, abs(height - lastBoundsHeight) > 0.5 {
            collectionView.contentOffset.y += lastBoundsHeight - height
        }
    }

    private func textSizeChanged() {
        heights.removeAll()
        let anchor = followsNewest ? nil : captureAnchor()
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        if let anchor { restore(anchor) }
        if followsNewest { scrollToNewest() }
    }

    // MARK: Reading ahead

    /// The next page is asked for while the reader is within `readAheadScreens` of the edge, so a
    /// fling meets rows, not a spinner. Checked on every scroll step and after every update (a page
    /// that leaves the reader near the edge asks for the next).
    private func queueReadAhead() {
        guard !readAheadQueued else { return }
        readAheadQueued = true
        Task { @MainActor [weak self] in
            self?.readAheadQueued = false
            self?.readAheadIfNear()
        }
    }

    private func readAheadIfNear() {
        guard loaded, edge == .more, collectionView.bounds.height > 0 else { return }
        if collectionView.pagedScreensToEdge(direction) < readAheadScreens { loadMore() }
    }

    // MARK: Scrolling

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        pullToRefresh?.willEndDragging(targetContentOffset: targetContentOffset)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pullToRefresh?.scrolled()
        if scrollView.isTracking || scrollView.isDecelerating {
            switch direction {
            case .up: followsNewest = maxOffsetY - scrollView.contentOffset.y <= 4
            case .down: followsNewest = scrollView.contentOffset.y + scrollView.adjustedContentInset.top <= 4
            }
        }
        readAheadIfNear()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { probe?.scrolling?(true) }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { probe?.scrolling?(false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        pullToRefresh?.endedDecelerating()
        probe?.scrolling?(false)
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { followsNewest = direction == .down }

    // MARK: Swipe actions

    private func swipeConfiguration(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let swipeActions, case .row(let id)? = dataSource.itemIdentifier(for: indexPath), let item = items[id] else { return nil }
        let actions = swipeActions(item)
        guard !actions.isEmpty else { return nil }
        let contextual = actions.map { action in
            let handler = action.handler
            let one = UIContextualAction(style: action.removesRow ? .destructive : .normal, title: action.title) { @MainActor _, _, done in
                handler()
                done(true)
            }
            one.image = UIImage(systemName: action.systemImage)
            one.backgroundColor = UIColor(action.tint)
            return one
        }
        let configuration = UISwipeActionsConfiguration(actions: contextual)
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }
}
#endif
