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
final class WorkspacesListCell: UICollectionViewListCell {
    var heights: WorkspacesHeightCache?
    var key: WorkspacesHeightCache.Key?

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
        config.showsSeparators = true
        // Trailing only: a rightward swipe from the leading edge belongs to the team sidebar.
        config.leadingSwipeActionsConfigurationProvider = nil
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        config.itemSeparatorHandler = { [weak self] indexPath, separator in
            self?.separator(at: indexPath, separator) ?? separator
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
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            for section in sections {
                snapshot.appendSections([section.id])
                snapshot.appendItems(section.items, toSection: section.id)
            }
            dataSource.apply(snapshot, animatingDifferences: animated)
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

    /// Rows draw the separator under them from the text column; titles, group
    /// headers, Mac lines and placeholders draw none (as the SwiftUI list did).
    private func separator(at indexPath: IndexPath, _ separator: UIListSeparatorConfiguration) -> UIListSeparatorConfiguration {
        var separator = separator
        guard let (_, item) = item(at: indexPath), item.isRow else {
            separator.topSeparatorVisibility = .hidden
            separator.bottomSeparatorVisibility = .hidden
            return separator
        }
        let size = DynamicTypeSize(collectionView?.traitCollection.preferredContentSizeCategory ?? .large) ?? .large
        let leading = CmuxMobileListColumn.plain(size).text
        separator.topSeparatorVisibility = .hidden
        separator.bottomSeparatorVisibility = .visible
        // From the text column to the rows' trailing inset, as the SwiftUI list drew it.
        separator.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: leading, bottom: 0, trailing: 20)
        return separator
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
