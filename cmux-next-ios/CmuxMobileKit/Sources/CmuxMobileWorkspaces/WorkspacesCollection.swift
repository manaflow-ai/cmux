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
    /// The filtered Mac can't be used: what is wrong and Retry, above its last-known rows (cmux#52200).
    case recovery(String)
    /// A Mac workspace group's header.
    case group(WorkspaceGroupHeaderModel)
    /// Group by Folder: a folder's header over its loose rows.
    case folder(WorkspaceFolderHeaderModel)
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

struct WorkspaceFolderHeaderModel: Equatable {
    var folder: String
    var count: Int
}

struct WorkspaceFoldLineModel: Equatable {
    var fold: WorkspaceInbox.Fold
    var isOpen: Bool
    /// Filtered to this Mac: its rows alone, no line.
    var showsLine: Bool
    var typeSize: DynamicTypeSize
    var canReconnect: Bool
    var sameNames: MacNameDisambiguation
}

/// A view that reads the minute clock in its own body, so a tick redraws it and not the list
/// that holds it (a Mac line's "Last seen 4m ago").
struct OnMinute<Content: View>: View {
    let content: (Date) -> Content
    var body: some View { content(MinuteClock.shared.now) }
}

/// The Workspaces list's sections and items, as the collection shows them.
struct WorkspacesListModel: Equatable {
    var sections: [ListSectionIDs] = []
    var items: [String: WorkspacesListItem] = [:]
    /// Which model this is (the inbox memo's build), and, for a model updated from another one
    /// with the same sections, that model's version and the items it changed: the list applies
    /// those items alone instead of comparing every section and item.
    var version = 0
    var patchedFrom: Int?
    var patchedItems: Set<String> = []
    /// Of a patched model: the items that moved within their section (the rest kept their order).
    var patchedMoves: Set<String> = []

    static func == (a: Self, b: Self) -> Bool { a.sections == b.sections && a.items == b.items }

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

    /// Reveal Workspace in List: the item scrolls to the middle and flashes once.
    func reveal(_ itemID: String) {
        controller?.reveal(itemID)
    }
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
        // Room under the last row for the New Task button that floats over the list's bottom.
        let bottomRoom = context.environment.cmuxMobileFloatingBottomRoom
        if view.contentInset.bottom != bottomRoom {
            view.contentInset.bottom = bottomRoom
            view.verticalScrollIndicatorInsets.bottom = bottomRoom
        }
    }
}

/// The list's collection view: its screen's content scroll view, so the
/// navigation bar's scroll edge, the search drawer and the tab bar's
/// minimize on scroll follow it.
final class WorkspacesCollectionView: UICollectionView {
    /// VoiceOver's three-finger scroll down at the top refreshes, as it does with `UIRefreshControl`.
    var accessibilityRefresh: (() -> Bool)?

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

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if direction == .up, accessibilityRefresh?() == true { return true }
        return super.accessibilityScroll(direction)
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
        // A Mac line's "Last seen 4m ago" moves on in its own view (`OnMinute`) with no new
        // value, so its height is measured each time, never cached (a few lines, one per Mac).
        if case .fold = key.item { return nil }
        if let shape = shape(key.item), let known = shapes[shape], known.width == width {
            hits += 1
            return known.height
        }
        guard let entry = entries[key.id], entry.width == width, entry.item == key.item else { return nil }
        hits += 1
        return entry.height
    }

    func store(_ key: Key, width: CGFloat, height: CGFloat) {
        if case .fold = key.item { return }
        if let shape = shape(key.item) {
            shapes[shape] = (width, height)
        } else {
            entries[key.id] = Entry(item: key.item, width: width, height: height)
        }
    }

    /// A row's shape: what its height depends on below the accessibility sizes
    /// (one line each for the name and the status, or the name alone). Nil at accessibility sizes,
    /// where the name and the status wrap to two lines: measured per row.
    private func shape(_ item: WorkspacesListItem) -> String? {
        guard case let .row(model) = item, !textSize.isAccessibilityCategory else { return nil }
        let icon = model.workspace.icon ?? ""
        let iconKind = icon.isEmpty ? "none" : (WorkspaceSwatch.isSymbol(icon) ? "symbol" : "emoji")
        // One line (compact, or a blank status line that the row leaves out) or two.
        let oneLine = !WorkspaceRow.showsStatusLine(model.workspace, status: model.status, macName: model.macName, compact: model.compact)
        return "row.\(iconKind)\(oneLine ? ".compact" : "")"
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
        #if DEBUG
        ListApplyProbe.shared.count("ws.cell.fit")
        #endif
        if let key, let heights, let height = heights.height(key, width: width) {
            let fitted = attributes.copy() as? UICollectionViewLayoutAttributes ?? attributes
            fitted.size = CGSize(width: width, height: height)
            return fitted
        }
        let fitted = super.preferredLayoutAttributesFitting(attributes)
        #if DEBUG
        ListApplyProbe.shared.count("ws.cell.measure")
        #endif
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
    /// Pull to refresh under the search field (`ListPullToRefresh` says why not `UIRefreshControl`).
    private var pullToRefresh: ListPullToRefresh?
    /// When the list last moved (`scrollViewDidScroll`): a change that lands while it moves
    /// applies without animation (`isScrolling`).
    private var lastScrolled: CFTimeInterval = -.infinity
    /// Animated snapshots applied, and the ones held to a plain apply because the list was
    /// moving (tests and the rig read them).
    private(set) var animatedApplyCount = 0
    private(set) var unanimatedWhileScrollingCount = 0
    /// Snapshots and reconfigures applied (tests and the rig read them).
    private(set) var applyCount = 0
    /// Passes that applied waiting changes (one per run-loop turn however many updates came).
    private(set) var applyPasses = 0
    /// Passes that applied only a model's changed items (tests).
    private(set) var patchedApplyCount = 0
    /// The items the last pass redrew in place (tests).
    private(set) var lastReconfigured: [String] = []
    private var shownVersion = 0
    private var pendingItems: Set<String>?
    private var pendingMoves: Set<String> = []
    private var lastMovedCount = 0
    private var lastWasPatched = false
    /// Passes that moved a patched model's moved items alone (tests).
    private(set) var movedApplyCount = 0
    /// Applies that kept the row being read in place (tests).
    private(set) var anchoredApplyCount = 0
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
        #if DEBUG
        ListApplyProbe.shared.count("ws.cell.configure")
        #endif
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
        case .folder: EdgeInsets(top: 10, leading: 0, bottom: 2, trailing: 20)
        case .fold: EdgeInsets(top: 10, leading: 0, bottom: 4, trailing: 20)
        case .asleep, .recovery: EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
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
        // A model updated from the one shown (or from the one already waiting), with the same
        // sections: only its changed items need applying. Anything else compares the whole list.
        let base = pending?.version ?? shownVersion
        if let from = model.patchedFrom, from == base, pending == nil || pendingItems != nil {
            pendingItems = (pendingItems ?? []).union(model.patchedItems)
            pendingMoves.formUnion(model.patchedMoves)
        } else {
            pendingItems = nil
            pendingMoves = []
        }
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
        applyPasses += 1
        #if DEBUG
        let started = CACurrentMediaTime()
        let configured = reconfigureCount
        defer { noteApply(started: started, configuredBefore: configured) }
        #endif
        heights.textSize = collectionView?.traitCollection.preferredContentSizeCategory ?? .large
        guard let next = pending, let dataSource else { return }
        pending = nil
        let changedItems = pendingItems
        let movedItems = pendingMoves
        lastMovedCount = movedItems.count
        lastWasPatched = changedItems != nil
        pendingItems = nil
        pendingMoves = []
        shownVersion = next.version
        var animated = pendingAnimated && !UIAccessibility.isReduceMotionEnabled && collectionView?.window != nil
        pendingAnimated = false
        // Never an animated whole-list snapshot under a moving list (a new workspace or a Needs
        // You change from a busy Mac, mid-scroll): it animated every row, and the frame it ran
        // in dropped. The change shows at once instead; at rest, rows still animate in.
        if animated, isScrolling(now: CACurrentMediaTime()) {
            animated = false
            unanimatedWhileScrollingCount += 1
        }
        if animated { animatedApplyCount += 1 }
        #if DEBUG
        ListApplyProbe.shared.applied("workspaces")
        #endif
        let sections: [ListSectionIDs]
        let plan: ListApplyPlan
        if let changedItems, !shownSections.isEmpty {
            // The shown sections, with only the moved items in new places: the changed items alone
            // are compared and redrawn (O(changed)).
            sections = movedItems.isEmpty ? shownSections : next.sections
            plan = ListApplyPlan(orderChanged: !movedItems.isEmpty, membershipChanged: false,
                                 reconfigure: changedItems.filter { id in
                                     guard let before = items[id], let after = next.items[id] else { return false }
                                     return before != after
                                 })
            patchedApplyCount += 1
        } else {
            sections = ListSectionIDs.unique(next.sections)
            plan = ListApplyPlan.make(old: shownSections, oldItems: items, new: sections, newItems: next.items)
        }
        items = next.items
        lastReconfigured = plan.reconfigure
        let now = CACurrentMediaTime()
        // A live reorder while the person scrolls (finger down or coasting) waits for the scroll
        // to rest: the rows update in place, and the order catches up in one apply at rest
        // (`applyDeferredOrder`). Rows coming or going, and a row into or out of Needs You (a
        // change of a section's rows), apply at once. Moving a row of a long list re-lays out
        // every row between its places, a frame's budget on a busy Mac's every tick.
        if plan.orderChanged, !plan.membershipChanged, !shownSections.isEmpty, isScrolling(now: now),
           changedItems != nil || Self.sameRows(shownSections, sections) {
            deferredSections = sections
            deferredReorderCount += 1
            noteReorderCounts()
            scheduleRestCheck()
            reconfigureShown(plan.reconfigure)
            return
        }
        if !plan.orderChanged, deferredSections != nil {
            // Rows changed in place: the order the scroll holds stays deferred.
            reconfigureShown(plan.reconfigure)
            return
        }
        deferredSections = nil
        guard !plan.isEmpty || dataSource.snapshot().numberOfSections == 0 && !sections.isEmpty else { return }
        if plan.orderChanged, !plan.membershipChanged, !shownSections.isEmpty, isAtRestAtTop() {
            // At the top, at rest: a row moving to the top slides there.
            animated = !UIAccessibility.isReduceMotionEnabled
        }
        applyOrder(sections, plan: plan, moved: changedItems != nil && shownMatchesSnapshot ? movedItems : nil, animated: animated)
        // Changed rows: the cells on screen take their new value in place (only a
        // cell whose height changes asks the layout again); every other cell is
        // filled when it is dequeued or comes on screen. A `reconfigureItems`
        // snapshot re-solved the whole list's layout for each change.
        reconfigureShown(plan.reconfigure)
    }

    /// Shows `sections`: the moved items alone (`moved`, a patched model's, or a few found by
    /// `moves`), or a new snapshot; the row being read stays in place when nothing animates.
    /// `resting`: the held order applied as the scroll ends (UIKit's end callbacks still read as
    /// scrolling then), not a reorder under a moving list.
    private func applyOrder(_ sections: [ListSectionIDs], plan: ListApplyPlan, moved: Set<String>?, animated: Bool,
                            resting: Bool = false) {
        guard let dataSource else { return }
        let anchor = animated ? nil : readingAnchor()
        if plan.orderChanged || dataSource.snapshot().numberOfSections == 0 {
            if let moved, !moved.isEmpty, !plan.membershipChanged {
                var snapshot = dataSource.snapshot()
                var places: [(section: Int, index: Int, id: String)] = []
                for (s, section) in sections.enumerated() {
                    for (index, id) in section.items.enumerated() where moved.contains(id) { places.append((s, index, id)) }
                }
                // Last first: each moved item goes before the item that follows it in the new
                // order, which is already in its final place.
                for place in places.sorted(by: { ($0.section, $0.index) > ($1.section, $1.index) }) {
                    let items = sections[place.section].items
                    if place.index + 1 < items.count {
                        snapshot.moveItem(place.id, beforeItem: items[place.index + 1])
                    } else if let last = snapshot.itemIdentifiers(inSection: sections[place.section].id).last, last != place.id {
                        snapshot.moveItem(place.id, afterItem: last)
                    }
                }
                dataSource.apply(snapshot, animatingDifferences: animated)
                movedApplyCount += 1
            } else if !plan.membershipChanged, !shownSections.isEmpty, let moves = Self.moves(from: shownSections, to: sections) {
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
                dataSource.apply(snapshot, animatingDifferences: animated)
                movedApplyCount += 1
            } else {
                var snapshot = NSDiffableDataSourceSnapshot<String, String>()
                for section in sections {
                    snapshot.appendSections([section.id])
                    snapshot.appendItems(section.items, toSection: section.id)
                }
                dataSource.apply(snapshot, animatingDifferences: animated)
            }
            applyCount += 1
            if !resting, isScrolling(now: CACurrentMediaTime()), !plan.membershipChanged { movedWhileScrollingCount += 1 }
            if let anchor { restore(anchor) }
        }
        shownSections = sections
        noteReorderCounts()
    }

    /// Reorders applied while the list moved (none: they wait for rest; tests and UI tests).
    private(set) var movedWhileScrollingCount = 0

    /// DEBUG: the reorder counts as the list's accessibility value, for UI tests.
    private func noteReorderCounts() {
        #if DEBUG
        collectionView?.accessibilityValue = "held=\(deferredReorderCount) rested=\(restedApplyCount) movedWhileScrolling=\(movedWhileScrollingCount)"
        #endif
    }

    /// The shown snapshot is in `shownSections`' order (no reorder is held back): a patched
    /// model's moves apply to it as they are.
    private var shownMatchesSnapshot: Bool { deferredSections == nil }

    /// The order a scroll held back (`applyPending`), applied when the scroll rests.
    private var deferredSections: [ListSectionIDs]?
    /// Reorders held back while scrolling, and the applies that caught up at rest (tests).
    private(set) var deferredReorderCount = 0
    private(set) var restedApplyCount = 0

    /// Applies the order a scroll held back, once the list rests: the row being read stays in
    /// place; at the top, the moved rows slide there (none with Reduce Motion).
    /// `ended`: the scroll just ended (UIKit's end-of-drag and end-of-deceleration callbacks run
    /// while `isDragging` / `isDecelerating` still read true, so they do not ask).
    func applyDeferredOrder(ended: Bool = false) {
        guard let target = deferredSections, ended || !isScrolling(now: CACurrentMediaTime()) else { return }
        deferredSections = nil
        let plan = ListApplyPlan(orderChanged: target != shownSections, membershipChanged: false, reconfigure: [])
        guard plan.orderChanged else { return }
        let animated = isAtRestAtTop() && !UIAccessibility.isReduceMotionEnabled
        restedApplyCount += 1
        applyOrder(target, plan: plan, moved: nil, animated: animated, resting: true)
    }

    /// At the top of the list (nothing scrolled under the bars) and on screen.
    private func isAtRestAtTop() -> Bool {
        guard let collectionView, collectionView.window != nil else { return false }
        return collectionView.contentOffset.y + collectionView.adjustedContentInset.top <= 0.5
    }

    /// Whether every section shows the same rows, in any order (a pure reorder).
    static func sameRows(_ a: [ListSectionIDs], _ b: [ListSectionIDs]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.id == y.id, x.items.count == y.items.count, Set(x.items) == Set(y.items) else { return false }
        }
        return true
    }

    /// A scroll the rig drives sets no dragging flags and ends no deceleration: look again once
    /// the moving window has passed (DEBUG only; a finger's scroll ends in the delegate).
    private func scheduleRestCheck() {
        #if DEBUG
        guard ListApplyProbe.shared.codeDrivenScroll, !restCheckScheduled else { return }
        restCheckScheduled = true
        // A run-loop timer in the common modes, not the main dispatch queue: code that spins the
        // run loop from inside a main-queue block (a test host, a modal) never drains that queue.
        let timer = Timer(timeInterval: Self.movingWindow + 0.02, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restCheckScheduled = false
                if self.isScrolling(now: CACurrentMediaTime()) { self.scheduleRestCheck() } else { self.applyDeferredOrder() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        #endif
    }

    #if DEBUG
    private var restCheckScheduled = false
    #endif

    #if DEBUG
    private func noteApply(started: CFTimeInterval, configuredBefore: Int) {
        let probe = ListApplyProbe.shared
        probe.count("ws.apply")
        probe.count("ws.apply.redrawn", reconfigureCount - configuredBefore)
        layoutIfNeededForProbe()
        let ms = (CACurrentMediaTime() - started) * 1000
        if ms > 4 {
            probe.onSlowApply?(String(format: "ws-apply ms=%.1f redrawn=%d moved=%d patched=%d whole_items=%d sections=%d",
                                      ms, reconfigureCount - configuredBefore, lastMovedCount, lastWasPatched ? 1 : 0,
                                      items.count, shownSections.count))
        }
    }

    /// The layout the apply leaves (the cells it invalidated measure now), inside its timing.
    private func layoutIfNeededForProbe() {
        guard ListApplyProbe.shared.counting else { return }
        collectionView?.layoutIfNeeded()
    }
    #endif

    /// The item ids the list shows in `section`, in order (tests).
    func shownItemIDs(inSection section: String) -> [String] {
        dataSource?.snapshot().itemIdentifiers(inSection: section) ?? []
    }

    /// The changed rows on screen take their new value in place.
    private func reconfigureShown(_ ids: [String]) {
        guard let dataSource else { return }
        for id in ids {
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
        guard let collectionView, wanted != (pullToRefresh != nil) else { return }
        if wanted {
            pullToRefresh = ListPullToRefresh(scrollView: collectionView) { [weak self] in
                await self?.actions?.refresh?()
            }
            collectionView.accessibilityRefresh = { [weak self] in self?.pullToRefresh?.accessibilityRefresh() ?? false }
        } else {
            pullToRefresh?.detach()
            pullToRefresh = nil
            collectionView.accessibilityRefresh = nil
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        lastScrolled = CACurrentMediaTime()
        pullToRefresh?.scrolled()
    }

    /// The list is moving under the person: a finger on it, or coasting. An offset change the
    /// list makes itself (an inset, a content-size change) is not scrolling.
    func isScrolling(now: CFTimeInterval) -> Bool {
        guard let view = collectionView else { return false }
        if view.isTracking || view.isDragging || view.isDecelerating { return true }
        #if DEBUG
        // The rig scrolls from code, which sets no dragging flag.
        if ListApplyProbe.shared.codeDrivenScroll { return now - lastScrolled < Self.movingWindow }
        #endif
        return false
    }

    /// How long after the last offset change the list still counts as moving.
    static let movingWindow: CFTimeInterval = 0.1

    // MARK: The row being read

    struct ReadingAnchor { var ids: [(id: String, delta: CGFloat)] }

    /// The rows on screen, top first, and where each starts relative to the scroll offset; nil at
    /// the top of the list (there a new row shows at the top). The first one that is still listed
    /// after an apply keeps its place (the row being read, or the next one when it left).
    func readingAnchor() -> ReadingAnchor? {
        guard let collectionView, let dataSource, collectionView.window != nil else { return nil }
        let offset = collectionView.contentOffset.y
        let top = offset + collectionView.adjustedContentInset.top
        guard top > 0.5 else { return nil }
        var ids: [(id: String, delta: CGFloat)] = []
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame, frame.maxY > top,
                  let id = dataSource.itemIdentifier(for: indexPath) else { continue }
            ids.append((id, frame.minY - offset))
        }
        return ids.isEmpty ? nil : ReadingAnchor(ids: ids)
    }

    private func restore(_ anchor: ReadingAnchor) {
        guard let collectionView, let dataSource else { return }
        collectionView.layoutIfNeeded()
        for (id, delta) in anchor.ids {
            guard let indexPath = dataSource.indexPath(for: id),
                  let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { continue }
            let minY = -collectionView.adjustedContentInset.top
            let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom)
            let y = min(max(frame.minY - delta, minY), maxY)
            // Not `setContentOffset(_:animated:)`: a plain offset keeps a finger's drag and a coast going.
            if abs(y - collectionView.contentOffset.y) > 0.25 {
                collectionView.contentOffset.y = y
                anchoredApplyCount += 1
            }
            return
        }
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        pullToRefresh?.scrolled()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        pullToRefresh?.endedDecelerating()
        applyDeferredOrder(ended: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { applyDeferredOrder(ended: true) }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        applyDeferredOrder(ended: true)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        pullToRefresh?.willEndDragging(targetContentOffset: targetContentOffset)
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

    /// The item in the middle of the list, then a press fill that fades on its cell.
    func reveal(_ itemID: String) {
        guard let collectionView, let indexPath = dataSource?.indexPath(for: itemID) else { return }
        let flash = { [weak collectionView] in
            guard let cell = collectionView?.cellForItem(at: indexPath) else { return }
            let fill = UIView(frame: cell.bounds)
            fill.backgroundColor = theme.colors.fillPressed.uiColor
            fill.isUserInteractionEnabled = false
            fill.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            fill.accessibilityIdentifier = "workspaces.revealed"
            cell.addSubview(fill)
            // A fade, not motion: kept under Reduce Motion too. The fill holds a moment first.
            UIView.animate(withDuration: 1.2, delay: 0.4, options: [.curveEaseOut], animations: { fill.alpha = 0 }) { _ in
                fill.removeFromSuperview()
            }
            UIAccessibility.post(notification: .layoutChanged, argument: cell)
        }
        // Reduce Motion: the list jumps there.
        guard !UIAccessibility.isReduceMotionEnabled else {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
            return flash()
        }
        let animator = theme.motion.smooth.animator()
        animator.addAnimations {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        animator.addCompletion { _ in flash() }
        animator.startAnimation()
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
