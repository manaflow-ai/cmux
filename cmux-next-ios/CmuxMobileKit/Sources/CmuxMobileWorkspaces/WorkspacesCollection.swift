#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// One item of the Workspaces list, as plain values: a row's whole input, so
/// the list reconfigures exactly the items whose value changed.
enum WorkspacesListItem: Equatable {
    /// "Needs You", "Pinned", "Workspaces" / "Recent": a title that scrolls with the rows.
    case title(String)
    /// Every Mac is asleep (All Macs, no search).
    case asleep
    /// A Mac workspace group's header.
    case group(WorkspaceGroupHeaderModel)
    /// One Mac's folded line (offline, not linked, or failed).
    case fold(WorkspaceFoldLineModel)
    case row(WorkspaceRowModel)
    /// Placeholder rows under the Mac lines while a Mac links.
    case loading

    var isRow: Bool {
        if case .row = self { return true }
        return false
    }
}

struct WorkspaceGroupHeaderModel: Equatable {
    var group: MacWorkspaceGroup
    var macID: String
    var count: Int
    var canEdit: Bool
}

struct WorkspaceFoldLineModel: Equatable {
    var fold: WorkspaceInbox.Fold
    var isOpen: Bool
    /// Filtered to this Mac: its rows alone, no line.
    var showsLine: Bool
    var typeSize: DynamicTypeSize
    var canReconnect: Bool
    var sameNames: MacNameDisambiguation
    var now: Date
}

/// The Workspaces list's sections and items, as the collection shows them.
struct WorkspacesListModel: Equatable {
    var sections: [ListSectionIDs] = []
    var items: [String: WorkspacesListItem] = [:]

    static func rowID(_ workspaceID: String) -> String { "ws.\(workspaceID)" }
}

/// A row cell's SwiftUI content.
typealias WorkspaceListRowCellContent = EquatableView<WorkspaceListRow>

/// What the list's owner gives the collection: each item's SwiftUI content
/// and its menu and swipe actions, all read on demand, and the refresh.
@MainActor
struct WorkspacesCollectionActions {
    /// A row's content (a concrete view, so a reused row cell updates its graph in place).
    var row: (WorkspaceRowModel) -> WorkspaceListRowCellContent
    /// Every other item's content (titles, group headers, Mac lines, placeholders).
    var content: (String, WorkspacesListItem) -> AnyView
    /// A row's or a group header's long-press menu, built when it opens.
    var menu: (String, WorkspacesListItem) -> UIMenu?
    /// A row's trailing swipe actions (nil: none).
    var swipe: (String, WorkspacesListItem) -> UISwipeActionsConfiguration?
    /// Pull to refresh (live only).
    var refresh: (() async -> Void)?
}

/// Scrolls the Workspaces list from its owner (the close popover, a fold
/// opening below the fold) and reads where its visible area ends.
@MainActor
final class WorkspacesListControl {
    weak var controller: WorkspacesListController?

    /// Brings an item to the top or the bottom of the visible area, then runs `completion`.
    func scrollTo(_ itemID: String, atTop: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        guard let controller else { completion?(); return }
        controller.scrollTo(itemID, atTop: atTop, animated: animated, completion: completion)
    }

    /// Where the list's visible area ends (above the tab bar), in the list's space.
    var visibleBottom: CGFloat { controller?.visibleBottom ?? .infinity }
}

/// The Workspaces list (SPEC 11.1) as a UIKit collection view: a plain list
/// layout, a diffable data source keyed by stable section and item ids, and
/// each item's SwiftUI content in a `UIHostingConfiguration`. A live update
/// applies at most one snapshot per run-loop turn and reconfigures only the
/// items whose value changed, so it costs O(changed rows); the SwiftUI List it
/// replaced re-diffed and re-laid out every row on each Mac tree update.
struct WorkspacesCollection: UIViewRepresentable {
    let model: WorkspacesListModel
    let actions: WorkspacesCollectionActions
    let control: WorkspacesListControl
    /// Rows came or went in the store (the list animates that).
    let membershipKey: Int

    func makeCoordinator() -> WorkspacesListController {
        WorkspacesListController(control: control)
    }

    func makeUIView(context: Context) -> WorkspacesCollectionView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: WorkspacesCollectionView, context: Context) {
        // A person's change (pin, group, filter) comes in an animated transaction.
        let animated = context.transaction.animation != nil && !context.transaction.disablesAnimations
        context.coordinator.update(model: model, actions: actions, animated: animated, membershipKey: membershipKey)
    }
}

/// The list's collection view: its screen's content scroll view, so the
/// navigation bar's scroll edge, the search drawer and the tab bar's
/// minimize on scroll follow it.
final class WorkspacesCollectionView: UICollectionView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                controller.setContentScrollView(self, for: .top)
                controller.setContentScrollView(self, for: .bottom)
                break
            }
            responder = next
        }
    }
}

/// Each item's height as SwiftUI measured it, for its value, the list's
/// width and the text size: a cell that comes on screen with a value it was
/// measured at before takes that height without a SwiftUI sizing pass (it
/// cost most of the main thread while scrolling). Bounded by the list's items.
@MainActor
final class WorkspacesHeightCache {
    struct Key {
        var id: String
        var item: WorkspacesListItem
    }

    private struct Entry {
        var item: WorkspacesListItem
        var width: CGFloat
        var height: CGFloat
    }

    private var entries: [String: Entry] = [:]
    /// Row heights by shape: below the accessibility sizes a row is two
    /// single-line texts, so its height depends on its icon, not its words.
    private var shapes: [String: (width: CGFloat, height: CGFloat)] = [:]
    var textSize: UIContentSizeCategory = .large {
        didSet {
            guard textSize != oldValue else { return }
            entries.removeAll()
            shapes.removeAll()
        }
    }
    private(set) var hits = 0

    func height(_ key: Key, width: CGFloat) -> CGFloat? {
        if let shape = shape(key.item), let known = shapes[shape], known.width == width {
            hits += 1
            return known.height
        }
        guard let entry = entries[key.id], entry.width == width, entry.item == key.item else { return nil }
        hits += 1
        return entry.height
    }

    func store(_ key: Key, width: CGFloat, height: CGFloat) {
        if let shape = shape(key.item) {
            shapes[shape] = (width, height)
        } else {
            entries[key.id] = Entry(item: key.item, width: width, height: height)
        }
    }

    /// A row's shape: what its height depends on below the accessibility sizes
    /// (one line each for the name and the status). Nil at accessibility sizes,
    /// where the name and the status wrap to two lines: measured per row.
    private func shape(_ item: WorkspacesListItem) -> String? {
        guard case let .row(model) = item, !textSize.isAccessibilityCategory else { return nil }
        let icon = model.workspace.icon ?? ""
        let iconKind = icon.isEmpty ? "none" : (WorkspaceSwatch.isSymbol(icon) ? "symbol" : "emoji")
        return "row.\(iconKind)"
    }
}

/// A list cell that takes its height from the cache when its value was measured before.
/// A plain cell, not a `UICollectionViewListCell`: a list cell asks its
/// hosting view for the separator's leading inset on every layout, a SwiftUI
/// layout pass per cell (a third of the main thread while scrolling). The list
/// layout still gives it swipe actions; it draws its own hairline.
final class WorkspacesListCell: UICollectionViewCell {
    var heights: WorkspacesHeightCache?
    var key: WorkspacesHeightCache.Key?
    /// The plain list's separator end, from the trailing edge.
    static let separatorTrailing: CGFloat = 16
    /// A hairline under a row, from the rows' text column to 16 pt from the trailing edge.
    var showsSeparator = false {
        didSet { hairline.isHidden = !showsSeparator }
    }
    private let hairline = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        hairline.backgroundColor = .separator
        hairline.isUserInteractionEnabled = false
        hairline.isHidden = true
        addSubview(hairline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 1 pt, as the plain list's separator measured on the iOS 26.5 simulator (3 px at 3x).
        let height: CGFloat = 1
        let size = DynamicTypeSize(traitCollection.preferredContentSizeCategory) ?? .large
        let leading = CmuxMobileListColumn.plain(size).text
        // To 16 pt from the trailing edge, where the plain list's separator ended
        // (measured: 1062 px from x = 96 px at 3x, 48 px short of the edge).
        hairline.frame = CGRect(x: leading, y: bounds.height - height, width: max(0, bounds.width - leading - Self.separatorTrailing), height: height)
        bringSubviewToFront(hairline)
    }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let width = attributes.size.width
        if let key, let heights, let height = heights.height(key, width: width) {
            let fitted = attributes.copy() as? UICollectionViewLayoutAttributes ?? attributes
            fitted.size = CGSize(width: width, height: height)
            return fitted
        }
        let fitted = super.preferredLayoutAttributesFitting(attributes)
        if let key, let heights { heights.store(key, width: width, height: fitted.size.height) }
        return fitted
    }
}

@MainActor
final class WorkspacesListController: NSObject, UICollectionViewDelegate {
    private let control: WorkspacesListControl
    private(set) var collectionView: WorkspacesCollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<String, String>?
    private var actions: WorkspacesCollectionActions?
    /// The shown items' values (what the cells were configured from).
    private var items: [String: WorkspacesListItem] = [:]
    private var shownSections: [ListSectionIDs] = []
    /// The latest model, applied once per run-loop turn.
    private var pending: WorkspacesListModel?
    private var pendingAnimated = false
    private var applyScheduled = false
    private var membershipKey: Int?
    private var refreshControl: UIRefreshControl?
    /// Snapshots and reconfigures applied (tests and the rig read them).
    private(set) var applyCount = 0
    private(set) var reconfigureCount = 0

    init(control: WorkspacesListControl) {
        self.control = control
        super.init()
        control.controller = self
    }

    // MARK: Building the view

    func makeView() -> WorkspacesCollectionView {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.backgroundColor = .clear
        config.headerMode = .none
        // The cells draw their own hairline: a list separator asks each cell's
        // hosting view for its leading alignment, a SwiftUI layout pass per cell.
        config.showsSeparators = false
        // Trailing only: a rightward swipe from the leading edge belongs to the team sidebar.
        config.leadingSwipeActionsConfigurationProvider = nil
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        let listConfig = config
        let layout = UICollectionViewCompositionalLayout { index, environment in
            let section = NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: environment)
            // The gap SwiftUI's plain List drew between sections (`listSectionSpacing(4)`).
            section.contentInsets = NSDirectionalEdgeInsets(top: index == 0 ? 0 : Self.sectionSpacing, leading: 0, bottom: 0, trailing: 0)
            return section
        }
        let view = WorkspacesCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .onDrag
        view.contentInsetAdjustmentBehavior = .automatic
        // A row is a button (its press fill); the cell itself does not select.
        view.allowsSelection = false
        view.delegate = self
        view.accessibilityIdentifier = "workspaces.list"

        // Rows reuse row cells only: a reused cell keeps its SwiftUI graph and updates it in place.
        let rowCell = UICollectionView.CellRegistration<WorkspacesListCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id)
        }
        let otherCell = UICollectionView.CellRegistration<WorkspacesListCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: view) { [weak self] collectionView, indexPath, id in
            let isRow = MainActor.assumeIsolated { self?.items[id]?.isRow ?? false }
            return isRow ? collectionView.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: id)
                : collectionView.dequeueConfiguredReusableCell(using: otherCell, for: indexPath, item: id)
        }
        collectionView = view
        return view
    }

    /// Fills a cell with its item's current value, and remembers what it shows.
    private func configure(_ cell: WorkspacesListCell, _ id: String) {
        guard let item = items[id], let actions else { return }
        cell.heights = heights
        cell.key = WorkspacesHeightCache.Key(id: id, item: item)
        if case let .row(model) = item {
            cell.contentConfiguration = UIHostingConfiguration { actions.row(model) }
                .margins(.all, Self.margins(item))
                .minSize(width: nil, height: 0)
        } else {
            cell.contentConfiguration = UIHostingConfiguration { actions.content(id, item) }
                .margins(.all, Self.margins(item))
                .minSize(width: nil, height: 0)
        }
        var background = UIBackgroundConfiguration.clear()
        if item.isRow { background.backgroundColor = theme.colors.bg.uiColor }
        cell.backgroundConfiguration = background
        // Rows draw the separator under them from the text column; titles, group
        // headers, Mac lines and placeholders draw none (as the SwiftUI list did).
        cell.showsSeparator = item.isRow
        shown[ObjectIdentifier(cell)] = (id, item)
    }

    /// Each item's measured height for its value, width and text size.
    private let heights = WorkspacesHeightCache()

    /// What each cell was last filled with: a prepared cell that missed a
    /// change is filled again when it comes on screen.
    private var shown: [ObjectIdentifier: (id: String, item: WorkspacesListItem)] = [:]

    /// The space between sections, as the SwiftUI list had it.
    static let sectionSpacing: CGFloat = 4

    /// Each item's insets in its cell, as the SwiftUI list's row insets were.
    static func margins(_ item: WorkspacesListItem) -> EdgeInsets {
        switch item {
        case .row: EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 20)
        case .title: EdgeInsets(top: 14, leading: 0, bottom: 2, trailing: 20)
        case .group: EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 20)
        case .fold: EdgeInsets(top: 10, leading: 0, bottom: 4, trailing: 20)
        case .asleep: EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
        case .loading: EdgeInsets()
        }
    }

    // MARK: Updates

    func update(model: WorkspacesListModel, actions: WorkspacesCollectionActions, animated: Bool, membershipKey: Int) {
        self.actions = actions
        configureRefresh(actions.refresh != nil)
        // Rows coming or going animate; a live reorder or a content change does not.
        if let previous = self.membershipKey, previous != membershipKey { pendingAnimated = true }
        self.membershipKey = membershipKey
        if animated { pendingAnimated = true }
        pending = model
        guard !applyScheduled else { return }
        applyScheduled = true
        // Every write of this run-loop turn (a burst from the Mac) becomes one apply.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.applyPending() }
        }
    }

    private func applyPending() {
        applyScheduled = false
        heights.textSize = collectionView?.traitCollection.preferredContentSizeCategory ?? .large
        guard let next = pending, let dataSource else { return }
        pending = nil
        let animated = pendingAnimated && !UIAccessibility.isReduceMotionEnabled && collectionView?.window != nil
        pendingAnimated = false
        let sections = ListSectionIDs.unique(next.sections)
        let plan = ListApplyPlan.make(old: shownSections, oldItems: items, new: sections, newItems: next.items)
        items = next.items
        guard !plan.isEmpty || dataSource.snapshot().numberOfSections == 0 && !sections.isEmpty else { return }
        if plan.orderChanged || dataSource.snapshot().numberOfSections == 0 {
            if !animated, !plan.membershipChanged, let moves = Self.moves(from: shownSections, to: sections) {
                // A live reorder (a row went to the top): moved items only, in place.
                var snapshot = dataSource.snapshot()
                for move in moves {
                    if let before = move.before {
                        snapshot.moveItem(move.id, beforeItem: before)
                    } else {
                        snapshot.deleteItems([move.id])
                        snapshot.appendItems([move.id], toSection: move.section)
                    }
                }
                dataSource.apply(snapshot, animatingDifferences: false)
            } else {
                var snapshot = NSDiffableDataSourceSnapshot<String, String>()
                for section in sections {
                    snapshot.appendSections([section.id])
                    snapshot.appendItems(section.items, toSection: section.id)
                }
                dataSource.apply(snapshot, animatingDifferences: animated)
            }
            applyCount += 1
        }
        shownSections = sections
        // Changed rows: the cells on screen take their new value in place (only a
        // cell whose height changes asks the layout again); every other cell is
        // filled when it is dequeued or comes on screen. A `reconfigureItems`
        // snapshot re-solved the whole list's layout for each change.
        for id in plan.reconfigure {
            guard let indexPath = dataSource.indexPath(for: id),
                  let cell = collectionView?.cellForItem(at: indexPath) as? WorkspacesListCell else { continue }
            configure(cell, id)
            reconfigureCount += 1
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? WorkspacesListCell, let id = dataSource?.itemIdentifier(for: indexPath) else { return }
        if let last = shown[ObjectIdentifier(cell)], last.id == id, last.item == items[id] { return }
        configure(cell, id)
    }

    struct Move: Equatable {
        var id: String
        var section: String
        /// The item it now goes before; nil: last in its section.
        var before: String?
    }

    /// The few moves that turn `old` into `new` when only a handful of items
    /// changed place (same sections, same items): each moved item, placed before
    /// its new successor. Nil when the change is bigger than that (a new snapshot).
    static func moves(from old: [ListSectionIDs], to new: [ListSectionIDs], limit: Int = 8) -> [Move]? {
        guard old.map(\.id) == new.map(\.id) else { return nil }
        var moves: [Move] = []
        for (before, after) in zip(old, new) where before.items != after.items {
            guard Set(before.items) == Set(after.items) else { return nil }
            // Items outside the longest run kept in order are the moved ones.
            let kept = Set(longestKeptRun(before.items, after.items))
            for (index, id) in after.items.enumerated() where !kept.contains(id) {
                moves.append(Move(id: id, section: after.id, before: index + 1 < after.items.count ? after.items[index + 1] : nil))
                if moves.count > limit { return nil }
            }
        }
        // Apply from the end, so each "before" item is already where it belongs.
        return moves.reversed()
    }

    /// The items of `new` that keep their relative order from `old`, found
    /// greedily: a moved item is one whose old position breaks the run.
    private static func longestKeptRun(_ old: [String], _ new: [String]) -> [String] {
        let position = Dictionary(old.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Patience sorting over old positions in new order: the longest increasing subsequence.
        var tails: [Int] = []
        var tailIndex: [Int] = []
        var previous = Array(repeating: -1, count: new.count)
        for (index, id) in new.enumerated() {
            let value = position[id] ?? 0
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if tails[mid] < value { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[index] = tailIndex[low - 1] }
            if low == tails.count { tails.append(value); tailIndex.append(index) } else { tails[low] = value; tailIndex[low] = index }
        }
        var run: [String] = []
        var cursor = tailIndex.last ?? -1
        while cursor >= 0 {
            run.append(new[cursor])
            cursor = previous[cursor]
        }
        return run.reversed()
    }

    private func configureRefresh(_ wanted: Bool) {
        guard let collectionView, wanted != (refreshControl != nil) else { return }
        if wanted {
            let refresh = UIRefreshControl()
            refresh.addAction(UIAction { [weak self, weak refresh] _ in
                Task { @MainActor in
                    await self?.actions?.refresh?()
                    refresh?.endRefreshing()
                }
            }, for: .valueChanged)
            collectionView.refreshControl = refresh
            refreshControl = refresh
        } else {
            collectionView.refreshControl = nil
            refreshControl = nil
        }
    }

    // MARK: Rows

    private func item(at indexPath: IndexPath) -> (String, WorkspacesListItem)? {
        guard let id = dataSource?.itemIdentifier(for: indexPath), let item = items[id] else { return nil }
        return (id, item)
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let (id, item) = item(at: indexPath) else { return nil }
        return actions?.swipe(id, item)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let (id, item) = item(at: indexPaths[0]) else { return nil }
        switch item {
        case .row, .group: break
        default: return nil
        }
        // Built when it opens, from the list as it is then.
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            guard let self, let current = self.items[id] else { return nil }
            return self.actions?.menu(id, current)
        }
    }

    // MARK: Scrolling

    var visibleBottom: CGFloat {
        guard let collectionView else { return .infinity }
        return collectionView.bounds.height - collectionView.adjustedContentInset.bottom
    }

    func scrollTo(_ itemID: String, atTop: Bool, animated: Bool, completion: (() -> Void)?) {
        guard let collectionView, let indexPath = dataSource?.indexPath(for: itemID) else { completion?(); return }
        let position: UICollectionView.ScrollPosition = atTop ? .top : .bottom
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            collectionView.scrollToItem(at: indexPath, at: position, animated: false)
            collectionView.layoutIfNeeded()
            completion?()
            return
        }
        let animator = theme.motion.smooth.animator()
        animator.addAnimations {
            collectionView.scrollToItem(at: indexPath, at: position, animated: false)
            collectionView.layoutIfNeeded()
        }
        animator.addCompletion { _ in completion?() }
        animator.startAnimation()
    }
}
#endif
