#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileMarkdown
import CmuxMobileModel
import Observation
import SwiftUI
import UIKit

/// What the Feed screen reads from its list and asks of it.
@MainActor
@Observable
final class FeedListControl {
    /// The list shows its top (within 60 pt).
    var atTop = true
    /// Events that arrived above the reader while they read below the top (the "N new" pill).
    var newAbove = 0
    /// A jump to the top (the pill's) is under way: the pill stays until it lands.
    var jumpingToTop = false
    /// The stacks shown open (`FeedStacks`), by their newest event's id. Folded is the default.
    @ObservationIgnored var expandedStacks: Set<String> = []
    @ObservationIgnored fileprivate weak var controller: FeedListController?

    func scrollToTop(animated: Bool = true) { controller?.scrollToTop(animated: animated) }
    func scrollTo(id: String, animated: Bool = true) { controller?.scrollTo(id: id, animated: animated) }
    #if DEBUG
    func demo(_ command: DemoDirector.Command) { controller?.demo(command) }
    #endif
}

/// The Feed's list (verify/feed-perf-20261022.md): a `UITableView` whose
/// rows are UIKit views only (`FeedRowCell`), with a diffable data source
/// keyed by event id. Work follows the screen, not the list: the table holds an
/// estimate for every row and asks the height of the rows it shows; a row's
/// layout (`FeedRowLayout`) is computed when the row comes near the screen
/// (UIKit's prefetch, about a screen ahead, off the main thread), kept until its
/// event, row state or width changes, and gives that row its exact height, so
/// scrolling a row in costs placing reused views and nothing else. A width
/// change lays out the rows on screen again, once; the rest when they come in.
/// A table (not a collection view with its own layout) so the rows get UIKit's own trailing swipe actions (`UIContextualAction`): the
/// system slide, full swipe, haptic and VoiceOver actions, as in Mail. The SwiftUI rows it replaced
/// built and measured a full view tree for each row that scrolled in, 14 to
/// 20 ms of main-thread work each.
struct FeedCollection: UIViewControllerRepresentable {
    let items: [FeedItem]
    let context: FeedRowContext
    let swipe: FeedSwipeCoordinator
    let control: FeedListControl
    /// The chips, the refresh error and the empty states above the events (the one SwiftUI part).
    let header: AnyView
    /// Changes when the header's height can (it is measured again).
    let headerSignature: AnyHashable
    /// Changes when what the header shows does at the same height (its cell redraws).
    let headerContent: AnyHashable

    func makeCoordinator() -> FeedListController {
        FeedListController(context: context, swipe: swipe, control: control)
    }

    func makeUIViewController(context: Context) -> FeedCollectionController {
        FeedCollectionController(collection: context.coordinator.makeView())
    }

    func updateUIViewController(_ controller: FeedCollectionController, context: Context) {
        context.coordinator.update(items: items, header: header, signature: headerSignature, headerContent: headerContent)
        // Room under the last row for the New Task button that floats over the list's bottom.
        let bottomRoom = context.environment.cmuxMobileFloatingBottomRoom
        let list = controller.collection
        if list.contentInset.bottom != bottomRoom {
            list.contentInset.bottom = bottomRoom
            list.verticalScrollIndicatorInsets.bottom = bottomRoom
        }
    }
}

/// Owns the content scroll view explicitly. A UIViewRepresentable nested in a
/// SwiftUI background can find an intermediate hosting controller instead of
/// the screen, leaving the navigation bar without its scroll edge treatment.
final class FeedCollectionController: UIViewController {
    let collection: FeedCollectionView

    init(collection: FeedCollectionView) {
        self.collection = collection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = collection }

    override func viewDidLoad() {
        super.viewDidLoad()
        collection.topEdgeEffect.style = .soft
        setContentScrollView(collection, for: .top)
        setContentScrollView(collection, for: .bottom)
    }
}

final class FeedCollectionView: UITableView {
    var onWidthChange: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            let width = bounds.width
            // Not during this layout pass: the change applies snapshots and moves the offset.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.onWidthChange?(width) }
            }
        }
        super.layoutSubviews()
    }
}

@MainActor
final class FeedListController: NSObject, UITableViewDelegate, UITableViewDataSourcePrefetching, FeedRowCellDelegate {
    enum Section: Hashable { case header, events }
    static let headerID = "feed.header"
    /// The pinned group's label ("Needs you · 2"), the header section's second row while the
    /// whole Feed has open asks: under the chips, above the first ask.
    static let pinnedLabelID = "feed.needs-you-label"
    /// The most rows that travel at once when asks leave or join the pinned group; more is a rebuild.
    static let pinnedMoveLimit = 4
    /// How many rows before the end the next page of spilled events is read.
    static let loadOlderLead = 30
    /// A row's height before it is laid out (a one- or two-line event): the table sums estimates
    /// for the rows it has not shown instead of asking every row's height up front.
    static let estimatedRowHeight: CGFloat = 140

    let context: FeedRowContext
    let swipe: FeedSwipeCoordinator
    let control: FeedListControl
    private var store: FeedStore { context.store }

    private(set) var collectionView: FeedCollectionView?
    private var dataSource: FeedTableDataSource?
    private let layouts = FeedRowLayoutCache<FeedRowLayout>()
    private var states: [String: FeedRowState] = [:]
    private var items: [String: FeedItem] = [:]
    /// The events as the list shows them (the applied snapshot's order).
    private var shownOrder: [String] = []
    private var shownKeys: [String: FeedRowKey] = [:]
    /// `shownOrder` as a set, rebuilt only when the order changes.
    private var shownSet: Set<String> = []
    /// Each shown row's height (its shown layout's), so a commit reads no layout it did not change.
    private var shownHeights: [String: CGFloat] = [:]
    /// How many of the first shown rows are the pinned group (open asks, the whole Feed only).
    private var shownPinned = 0
    /// The latest events from the store, applied once per run-loop turn.
    private var pending: [FeedItem]?
    /// The store's events as last given (before stacking): a fold line's tap stacks them again.
    private var latest: [FeedItem] = []
    /// The stacks among `latest` (`FeedStacks`): each fold line by its row id, and the stacks' newest events.
    private var folds: [String: FeedFold] = [:]
    private var stackHeads: Set<String> = []
    /// The next commit is a fold line's toggle: its rows come and go with the table's own row animation.
    private var animatesNextCommit = false
    private var applyScheduled = false
    /// Layouts computed off the main thread, one batch at a time.
    private let queue = DispatchQueue(label: "dev.cmux.mobile.feed-layout", qos: .userInitiated)
    private var batchInFlight = false
    private var header = AnyView(EmptyView())
    private var headerSignature: AnyHashable?
    private var headerContent: AnyHashable?
    private var headerHeight: CGFloat = 0
    private let headerSizer = UIHostingController(rootView: AnyView(EmptyView()))
    private var width: CGFloat = 0
    private var scale: CGFloat = 3
    private var textSize: String { collectionView?.traitCollection.preferredContentSizeCategory.rawValue ?? UIContentSizeCategory.large.rawValue }
    /// The Feed has not scrolled for a moment: web bodies render.
    private(set) var rowsSettled = true
    private var lastScroll: CFTimeInterval = 0
    private var settleTask: Task<Void, Never>?
    private var replyChats: [String: AgentChatStore] = [:]
    private var previousRead: [String: Bool] = [:]
    /// Every event id the list has shown this session (the "N new" pill counts others only).
    private var everShown: Set<String> = []
    /// Snapshots applied (tests and the rig read it).
    private(set) var applyCount = 0
    /// Event rows whose height the table asked for (`heightForRowAt`).
    private(set) var heightQueries = 0
    /// Row layouts built (`FeedRowLayout.make`), on the main thread or off it.
    private(set) var rowsLaidOut = 0
    /// Event rows handed to a snapshot's `reconfigureItems`.
    private(set) var rowsReconfigured = 0
    /// Event cells the cell provider bound to a layout.
    private(set) var cellsConfigured = 0
    /// A snapshot or a layout batch is still on its way (tests wait for it).
    var hasPendingWork: Bool { applyScheduled || batchInFlight }

    init(context: FeedRowContext, swipe: FeedSwipeCoordinator, control: FeedListControl) {
        self.context = context
        self.swipe = swipe
        self.control = control
        super.init()
        control.controller = self
        headerSizer.sizingOptions = []
        headerSizer.view.backgroundColor = .clear
        observeSwipe()
    }

    // MARK: Building the view

    func makeView() -> FeedCollectionView {
        let view = FeedCollectionView(frame: .zero, style: .plain)
        view.backgroundColor = .cmuxMobileBackground
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.contentInsetAdjustmentBehavior = .automatic
        view.accessibilityIdentifier = "feed.list"
        // Rows draw their own divider; a row is not selected (its parts are the buttons).
        view.separatorStyle = .none
        view.allowsSelection = false
        view.cellLayoutMarginsFollowReadableWidth = false
        view.sectionHeaderTopPadding = 0
        // An estimate for rows not shown yet; a shown row's height is its layout's (heightForRowAt).
        // With no estimate (0) the table asked every row's height on each load and height change.
        view.estimatedRowHeight = Self.estimatedRowHeight
        view.estimatedSectionHeaderHeight = 0
        view.estimatedSectionFooterHeight = 0
        view.sectionHeaderHeight = 0
        view.sectionFooterHeight = 0
        view.delegate = self
        view.prefetchDataSource = self
        view.register(UITableViewCell.self, forCellReuseIdentifier: Self.headerID)
        view.register(FeedPinnedLabelCell.self, forCellReuseIdentifier: Self.pinnedLabelID)
        view.register(FeedRowCell.self, forCellReuseIdentifier: FeedRowCell.reuseID)
        view.register(FeedFoldCell.self, forCellReuseIdentifier: FeedFoldCell.reuseID)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { @MainActor in
                await self?.store.refresh()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        view.refreshControl = refresh
        let catcher = FeedJumpTouchCatcher(target: self, action: #selector(touchDuringJump(_:)))
        catcher.isArmed = { [weak self] in self?.jumpingToTop ?? false }
        view.addGestureRecognizer(catcher)
        view.onWidthChange = { [weak self] width in self?.widthChanged(width) }

        dataSource = FeedTableDataSource(tableView: view) { [weak self] tableView, indexPath, id in
            MainActor.assumeIsolated { () -> UITableViewCell in
                guard indexPath.section != 0 else {
                    if id == Self.pinnedLabelID {
                        let cell = tableView.dequeueReusableCell(withIdentifier: Self.pinnedLabelID, for: indexPath)
                        if let self, let label = cell as? FeedPinnedLabelCell {
                            label.show(count: self.shownPinned, font: FeedPinnedLabelCell.font(self.styles))
                        }
                        return cell
                    }
                    let cell = tableView.dequeueReusableCell(withIdentifier: Self.headerID, for: indexPath)
                    cell.selectionStyle = .none
                    cell.backgroundColor = .clear
                    if let self { cell.contentConfiguration = UIHostingConfiguration { self.header }.margins(.all, 0) }
                    return cell
                }
                if FeedStacks.isFold(id) {
                    let cell = tableView.dequeueReusableCell(withIdentifier: FeedFoldCell.reuseID, for: indexPath)
                    guard let self, let fold = cell as? FeedFoldCell, let layout = self.layout(for: id) else { return cell }
                    fold.onToggle = { [weak self] id in self?.toggleStack(fold: id) }
                    fold.apply(layout)
                    return fold
                }
                let cell = tableView.dequeueReusableCell(withIdentifier: FeedRowCell.reuseID, for: indexPath)
                guard let self, let row = cell as? FeedRowCell, let layout = self.layout(for: id) else { return cell }
                row.delegate = self
                self.cellsConfigured += 1
                row.apply(layout, item: self.items[id], settled: self.rowsSettled)
                row.leadsStack = self.stackHeads.contains(id)
                return row
            }
        }
        collectionView = view
        scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 3
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (view: FeedCollectionView, _: UITraitCollection) in
            guard let self else { return }
            self.headerSizer.traitOverrides.preferredContentSizeCategory = view.traitCollection.preferredContentSizeCategory
            // Not during the trait change's layout pass: both apply snapshots.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.measureHeader()
                    self?.relayoutAll()
                }
            }
        }
        followMinuteClock()
        #if DEBUG
        if FeedStressRig.shared.config.autoscrollPasses != nil { FeedScreenRig.scroller.attach(view) }
        #endif
        return view
    }

    /// Row times redraw on the shared minute clock's tick, which pauses in the
    /// background and ticks at once on return (no timer of the Feed's own).
    private func followMinuteClock() {
        withObservationTracking {
            _ = MinuteClock.shared.now
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.visibleCells.forEach { $0.refreshTime() }
                self.followMinuteClock()
            }
        }
    }

    private var visibleCells: [FeedRowCell] { collectionView?.visibleCells.compactMap { $0 as? FeedRowCell } ?? [] }

    // MARK: Store updates

    func update(items next: [FeedItem], header: AnyView, signature: AnyHashable, headerContent content: AnyHashable) {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("update y=\(Int(collectionView?.contentOffset.y ?? 0))", t0) }
        #endif
        self.header = header
        if signature != headerSignature {
            headerSignature = signature
            headerContent = content
            measureHeader()
        } else if content != headerContent {
            // A chip's count changed: the header cell reads its view again, at the same height.
            headerContent = content
            reconfigureHeader()
        }
        // The diffable source refuses a repeated id: keep the first (the store's order is newest first).
        var seen = Set<String>()
        latest = next.filter { seen.insert($0.id).inserted }
        stack()
        guard !applyScheduled else { return }
        applyScheduled = true
        // Every write of this run-loop turn (a burst from the Mac) becomes one snapshot.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.applyPending() }
        }
    }

    /// Folds each chat's run of events in `latest` into its newest event and a fold line; the result is `pending`.
    private func stack() {
        // A row whose reply is being written, or could not be sent, is never folded away.
        let open = Set(states.lazy.filter { $0.value.replying || $0.value.replyFailure != nil }.map(\.key))
        let stacks = FeedStacks(latest, expanded: &control.expandedStacks, open: open)
        folds = stacks.folds
        stackHeads = stacks.heads
        // A folded event is known, not new: showing it later (the stack opened) never counts for the "N new" pill.
        everShown.formUnion(stacks.hidden)
        pending = stacks.rows
    }

    /// A fold line was tapped: its stack's older events show under it, or fold away again.
    private func toggleStack(fold id: String) {
        guard let head = FeedStacks.head(ofFold: id) else { return }
        setStack(head: head, expanded: !control.expandedStacks.contains(head))
        CmuxMobileTheme.standard.haptics.selectionChanged()
    }

    func setStack(head: String, expanded: Bool) {
        guard stackHeads.contains(head), control.expandedStacks.contains(head) != expanded else { return }
        if expanded { control.expandedStacks.insert(head) } else { control.expandedStacks.remove(head) }
        stack()
        animatesNextCommit = true
        applyScheduled = true
        applyPending()
    }

    private func measureHeader() {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("measureHeader", t0) }
        #endif
        guard width > 0 else { return }
        headerSizer.rootView = header
        let height = ceil(headerSizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        guard abs(height - headerHeight) > 0.5 else {
            reconfigureHeader()
            return
        }
        headerHeight = height
        reconfigureHeader()
        // The table reads the header's new height.
        UIView.performWithoutAnimation { collectionView?.performBatchUpdates(nil) }
    }

    private func reconfigureHeader() {
        guard let dataSource, dataSource.snapshot().indexOfItem(Self.headerID) != nil else { return }
        var snapshot = dataSource.snapshot()
        // The pinned group's label follows the text size with the header.
        snapshot.reconfigureItems(shownPinned > 0 ? [Self.headerID, Self.pinnedLabelID] : [Self.headerID])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The row's layout key. The read flag and the time are drawn, not laid out, so a read
    /// on the Mac (several a second) redraws the dot without laying the row out again.
    private func key(for item: FeedItem) -> FeedRowKey {
        var laidOut = item
        laidOut.isRead = false
        laidOut.createdAt = .distantPast
        return FeedRowKey(item: laidOut, state: state(for: item.id), width: Int(width.rounded()), textSize: textSize)
    }

    /// The row's state as its layout reads it: the person's, or for a fold line its stack's count and whether it is open.
    private func state(for id: String) -> FeedRowState {
        if let fold = folds[id] { return FeedRowState(fold: fold) }
        return states[id] ?? FeedRowState()
    }

    private var styles: NativeTextStyles { NativeTextStyles(category: UIContentSizeCategory(rawValue: textSize)) }

    private func layout(for id: String) -> FeedRowLayout? {
        guard let item = items[id] else { return nil }
        let key = key(for: item)
        return layouts.value(for: key) { makeLayout(key) }
    }

    /// Builds one row's layout on the main thread.
    private func makeLayout(_ key: FeedRowKey) -> FeedRowLayout {
        rowsLaidOut += 1
        return FeedRowLayout.make(key, styles: styles, scale: scale)
    }

    private func applyPending() {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("applyPending y=\(Int(collectionView?.contentOffset.y ?? 0))", t0) }
        #endif
        applyScheduled = false
        guard let next = pending, width > 0, collectionView != nil else { return }
        // A pending question's card shows its saved draft (a relaunch keeps a partly answered question
        // where the person left it); a question answered or cancelled keeps no card state or draft.
        for item in next {
            guard case .question(let question) = item.kind else { continue }
            if question.isPending {
                if var state = states[item.id]?.question {
                    state.update(question)
                    states[item.id, default: FeedRowState()].question = state
                } else if let draft = QuestionDraftStore.shared.draft(for: question.id) {
                    states[item.id, default: FeedRowState()].question = draft.restore(into: question)
                }
            } else if states[item.id]?.question != nil {
                states[item.id]?.question = nil
                QuestionDraftStore.shared.clear(question.id)
            }
        }
        // A row whose event and state did not change keeps the key it is shown with: no copy, no
        // compare, no cache lookup (a live change touches one row; the store republishes all 300).
        var unchanged = Set<String>()
        let widthKey = Int(width.rounded()), size = textSize
        let keys: [(String, FeedRowKey)] = next.map { item in
            if !relayingOut, let shown = shownKeys[item.id], let old = items[item.id], shown.width == widthKey, shown.textSize == size,
               shown.state == state(for: item.id), old == item {
                unchanged.insert(item.id)
                return (item.id, shown)
            }
            return (item.id, key(for: item))
        }
        if relayingOut {
            // A width or text size change: the rows on screen are laid out again here, once, and
            // reconfigured; every other row when it scrolls in (heightForRowAt, prefetch).
            relayingOut = false
            let mounted = mountedIDs()
            for (id, key) in keys where mounted.contains(id) && layouts.cached(key) == nil { layouts.store(makeLayout(key), for: key) }
            commit(next, keys: keys, relayout: mounted)
            return
        }
        // Changed rows near the screen (one screen above and below) are laid out off the main thread
        // before the change shows; rows further away when they come in. A first load shows at once:
        // the table asks the heights of the rows it shows, and those are laid out then.
        if !shownOrder.isEmpty {
            let near = nearIDs(next)
            let missing = keys.filter { !unchanged.contains($0.0) && near.contains($0.0) && layouts.cached($0.1) == nil }.map(\.1)
            if !missing.isEmpty { computeInBackground(missing); return }
        }
        commit(next, keys: keys, unchanged: unchanged)
    }

    /// The event rows the table shows now (it keeps cells for these only).
    private func mountedIDs() -> Set<String> {
        guard let collectionView, let dataSource else { return [] }
        return Set((collectionView.indexPathsForVisibleRows ?? []).filter { $0.section == 1 }.compactMap { dataSource.itemIdentifier(for: $0) })
    }

    /// The rows on screen and one screen above and below them, read at their places in `next` and in
    /// the shown order (a row inserted above shifts the places; the shown order still names the rows on screen).
    private func nearIDs(_ next: [FeedItem]) -> Set<String> {
        let rows = (collectionView?.indexPathsForVisibleRows ?? []).filter { $0.section == 1 }.map(\.row)
        guard let first = rows.min(), let last = rows.max() else { return [] }
        let span = last - first + 1
        let low = max(0, first - span), high = last + span
        var near = Set<String>()
        if low < next.count { for item in next[low ..< min(next.count, high + 1)] { near.insert(item.id) } }
        if low < shownOrder.count { near.formUnion(shownOrder[low ..< min(shownOrder.count, high + 1)]) }
        return near
    }

    private func computeInBackground(_ keys: [FeedRowKey]) {
        guard !batchInFlight else { return }
        batchInFlight = true
        rowsLaidOut += keys.count
        let styles = styles, scale = scale
        queue.async { [weak self] in
            let built = keys.map { FeedRowLayout.make($0, styles: styles, scale: scale) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.batchInFlight = false
                    // A layout for a key that changed meanwhile is dropped (a newer one is or will be cached).
                    let current = Dictionary((self.pending ?? []).map { ($0.id, self.key(for: $0)) }, uniquingKeysWith: { first, _ in first })
                    for layout in built where current[layout.key.item.id].map({ $0 == layout.key }) ?? true {
                        self.layouts.store(layout, for: layout.key)
                    }
                    self.applyScheduled = true
                    self.applyPending()
                }
            }
        }
    }

    /// Applies `next` to the list: a new snapshot when the order changed, else a reconfigure of
    /// the rows whose layout key changed, keeping the row under the reader's eyes in place.
    /// `mounted`: a relayout (width or text size); only these rows (on screen) are reconfigured.
    private func commit(_ next: [FeedItem], keys: [(String, FeedRowKey)], relayout mounted: Set<String>? = nil, unchanged: Set<String> = []) {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("commit n=\(next.count)", t0) }
        #endif
        guard let dataSource, let collectionView else { return }
        var plan = FeedListPlan(oldOrder: shownOrder, shown: shownKeys, new: keys, unchanged: unchanged)
        if let mounted { plan.reconfigure = plan.reconfigure.filter { mounted.contains($0) } }
        for item in next where !unchanged.contains(item.id) { items[item.id] = item }
        // Read flags change no layout: those rows redraw their dot and actions in place.
        let reconfiguring = Set(plan.reconfigure)
        var redraw: [String] = []
        for item in next where !unchanged.contains(item.id) {
            if !reconfiguring.contains(item.id), let was = previousRead[item.id], was != item.isRead { redraw.append(item.id) }
            previousRead[item.id] = item.isRead
        }
        defer {
            for id in redraw { if let item = items[id] { cell(id)?.redraw(item) } }
            // A row that now leads a stack (or no longer does) hides or shows its divider in place.
            for cell in visibleCells { if let id = cell.layout?.key.item.id { cell.leadsStack = stackHeads.contains(id) } }
        }
        let animated = animatesNextCommit && !UIAccessibility.isReduceMotionEnabled && mounted == nil
        animatesNextCommit = false
        // The pinned group (open asks first, the whole Feed only) and its label's count.
        let pinned = FeedPinnedGroup.count(next, filter: store.filter)
        let wasPinned = shownPinned
        guard !plan.isEmpty || mounted != nil || pinned != wasPinned || dataSource.snapshot().numberOfSections == 0 else { return }
        // A jump to the top in flight keeps no anchor: restoring one would set the offset and cut the
        // jump's animation short wherever it was (the pill then left the person mid-list).
        // A fold line's toggle keeps no anchor either: its rows come and go below it, under the table's animation.
        var anchor = syncAtTop() || jumpingToTop || animated ? nil : visibleAnchor()
        let previousOrder = shownOrder
        let previousSet = shownSet
        shownOrder = next.map(\.id)
        if plan.orderChanged { shownSet = Set(shownOrder) }
        if plan.orderChanged || mounted != nil {
            shownKeys = Dictionary(keys, uniquingKeysWith: { first, _ in first })
        }
        // Each changed row's height, from the layout of the key it is shown with. A row with no layout
        // yet keeps no height: the table holds its estimate and asks when the row comes in. A relayout
        // forgets every height but the rows on screen (laid out again in applyPending).
        if mounted != nil { shownHeights.removeAll(keepingCapacity: true) }
        var heightChanged = mounted != nil
        for (id, key) in keys where !unchanged.contains(id) {
            shownKeys[id] = key
            guard mounted?.contains(id) ?? true, let layout = layouts.cached(key) else {
                if shownHeights.removeValue(forKey: id) != nil { heightChanged = true }
                continue
            }
            if let old = shownHeights[id], abs(old - layout.height) > 0.25 { heightChanged = true }
            shownHeights[id] = layout.height
        }
        var snapshot = dataSource.snapshot()
        // An answered ask travels from the pinned group to its place in time (the table's row move).
        var travelling: Set<String> = []
        shownPinned = pinned
        if snapshot.numberOfSections == 0 {
            snapshot = NSDiffableDataSourceSnapshot<Section, String>()
            snapshot.appendSections([.header, .events])
            snapshot.appendItems(pinned > 0 ? [Self.headerID, Self.pinnedLabelID] : [Self.headerID], toSection: .header)
            snapshot.appendItems(shownOrder, toSection: .events)
        } else {
            if plan.orderChanged {
                // Inserts and removals with the rest in order (a live event, a done swipe): edits, not a new
                // snapshot of every row to diff. An ask leaving or joining the pinned group: row moves.
                // Anything else (a re-sort) rebuilds the section.
                if !FeedListController.edit(&snapshot, from: previousOrder, to: shownOrder) {
                    let movers = Set(previousOrder.prefix(wasPinned)).symmetricDifference(shownOrder.prefix(pinned))
                    if let move = FeedMoveEdit(old: previousOrder, new: shownOrder, movers: movers, limit: Self.pinnedMoveLimit) {
                        FeedListController.apply(move, to: &snapshot)
                        travelling = movers
                    } else {
                        snapshot.deleteSections([.events])
                        snapshot.appendSections([.events])
                        snapshot.appendItems(shownOrder, toSection: .events)
                    }
                }
            }
            if pinned > 0, wasPinned == 0 {
                snapshot.insertItems([Self.pinnedLabelID], afterItem: Self.headerID)
            } else if pinned == 0, wasPinned > 0 {
                snapshot.deleteItems([Self.pinnedLabelID])
            } else if pinned != wasPinned {
                snapshot.reconfigureItems([Self.pinnedLabelID])
            }
        }
        // Reconfigured rows are shown rows by construction (the plan lists only ids it had shown); a
        // relayout's list may name rows the snapshot just removed.
        let reconfigure = plan.orderChanged ? plan.reconfigure.filter { shownSet.contains($0) && previousSet.contains($0) } : plan.reconfigure
        if !reconfigure.isEmpty { snapshot.reconfigureItems(reconfigure) }
        rowsReconfigured += reconfigure.count
        applyCount += 1
        if !travelling.isEmpty, !UIAccessibility.isReduceMotionEnabled, collectionView.window != nil {
            // The rows show their new state where they are (an answered card, at once), then the
            // table moves the answered ask to its place in time and closes the gap it left. The row
            // kept in place is never one that travels: the reader stays with the asks still open.
            if anchor.map({ travelling.contains($0.id) }) == true { anchor = visibleAnchor(excluding: travelling) }
            if !reconfigure.isEmpty {
                var inPlace = dataSource.snapshot()
                inPlace.reconfigureItems(reconfigure)
                UIView.performWithoutAnimation { dataSource.apply(inPlace, animatingDifferences: false) }
            }
            dataSource.apply(snapshot, animatingDifferences: true)
            if heightChanged { collectionView.performBatchUpdates(nil) }
            if let anchor { restore(anchor) }
            continueJumpToTop()
        } else if animated {
            // The stack's rows slide in under its fold line (or out), as the system inserts rows.
            dataSource.apply(snapshot, animatingDifferences: true)
        } else {
            UIView.performWithoutAnimation {
                dataSource.apply(snapshot, animatingDifferences: false)
                // A shown row has a new height: the table reads the heights again.
                if heightChanged { collectionView.performBatchUpdates(nil) }
                if let anchor { restore(anchor) }
                continueJumpToTop()
            }
        }
        if let anchor {
            // Only events never shown before count as new (an undone Done or a filter switch does not).
            let fresh = FeedListPlan.fresh(plan.inserted, seen: &everShown)
            let above = shownOrder.prefix { $0 != anchor.id }.count { fresh.contains($0) && !FeedStacks.isFold($0) }
            if above > 0 { control.newAbove += above }
        } else {
            _ = FeedListPlan.fresh(plan.inserted, seen: &everShown)
        }
        if !plan.inserted.isEmpty || !plan.reconfigure.isEmpty { scheduleWarmUp(plan.inserted + plan.reconfigure) }
        // Rows that left the list: only when some did (an insert or a move removes none).
        if plan.orderChanged, previousOrder.count + plan.inserted.count != shownOrder.count {
            let present = shownSet
            layouts.prune(keeping: present)
            items = items.filter { present.contains($0.key) }
            states = states.filter { present.contains($0.key) }
            replyChats = replyChats.filter { present.contains($0.key) }
            shownHeights = shownHeights.filter { present.contains($0.key) }
            previousRead = previousRead.filter { present.contains($0.key) }
        }
    }

    /// Turns `old` into `new` with deletes and inserts when the rows both keep stay in the same order.
    static func edit(_ snapshot: inout NSDiffableDataSourceSnapshot<Section, String>, from old: [String], to new: [String]) -> Bool {
        let plan = FeedSnapshotEdit(old: old, new: new)
        guard let plan else { return false }
        if !plan.removed.isEmpty { snapshot.deleteItems(plan.removed) }
        for group in plan.groups { snapshot.insertItems(group.ids, beforeItem: group.before) }
        if !plan.tail.isEmpty { snapshot.appendItems(plan.tail, toSection: .events) }
        return true
    }

    /// Applies an ask's move out of (or into) the pinned group, with the inserts and removals beside it.
    static func apply(_ move: FeedMoveEdit, to snapshot: inout NSDiffableDataSourceSnapshot<Section, String>) {
        if !move.removed.isEmpty { snapshot.deleteItems(move.removed) }
        for step in move.steps {
            switch step {
            case .move(let id, let before):
                if let before {
                    snapshot.moveItem(id, beforeItem: before)
                } else if let last = snapshot.itemIdentifiers(inSection: .events).last, last != id {
                    snapshot.moveItem(id, afterItem: last)
                }
            case .insert(let id, let before):
                if let before {
                    snapshot.insertItems([id], beforeItem: before)
                } else {
                    snapshot.appendItems([id], toSection: .events)
                }
            }
        }
    }

    // MARK: Warm-up

    /// Row shapes already drawn once (kind, body, quote, replies): the first draw of a font, a
    /// symbol or a code style cost ~20 ms on the frame a row of that shape first scrolled in.
    private var warmed: Set<String> = []
    private var warmQueue: [FeedRowLayout] = []
    private var warmScheduled = false
    private lazy var warmCell: FeedRowCell = {
        let cell = FeedRowCell(style: .default, reuseIdentifier: nil)
        cell.frame = CGRect(x: 0, y: 0, width: max(width, 1), height: 100)
        return cell
    }()

    static func shape(_ layout: FeedRowLayout) -> String {
        let item = layout.key.item
        let kind: String
        switch item.kind {
        case .response: kind = "response"
        case .question: kind = "question"
        case .permission: kind = "permission"
        case .finished: kind = "finished"
        case .failed: kind = "failed"
        case .needsInput: kind = "needsInput"
        }
        let body: String
        switch layout.body.content {
        case .inline: body = "inline"
        case .web: body = "web"
        case .native(let native):
            body = native.blocks.map { block -> String in
                switch block {
                case .text: "t"
                case .code: "c"
                case .table: "b"
                case .quote: "q"
                case .rule: "r"
                }
            }.joined()
        }
        return [kind, body, item.quote.map { "\($0.author)" } ?? "-", item.replies.isEmpty ? "" : "r", item.resolution == nil ? "" : "s",
                layout.body.overflowing ? "o" : ""].joined(separator: "|")
    }

    /// Draws one row of each shape not seen yet off screen, one per run-loop turn while idle.
    /// Queues a warm-up draw for the shapes among `ids` (the rows just added or changed) not seen yet.
    private func scheduleWarmUp(_ ids: [String]) {
        for id in ids {
            guard let key = shownKeys[id], let layout = layouts.cached(key), layout.fold == nil else { continue }
            let shape = Self.shape(layout)
            if warmed.insert(shape).inserted { warmQueue.append(layout) }
        }
        pumpWarmUp()
    }

    private func pumpWarmUp() {
        guard !warmScheduled, !warmQueue.isEmpty else { return }
        warmScheduled = true
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.warmScheduled = false
                // Not while the list moves: a warm-up draw is the cost it saves a later frame.
                if let view = self.collectionView, view.isTracking || view.isDecelerating || !self.rowsSettled {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(200))
                        self?.pumpWarmUp()
                    }
                    return
                }
                #if DEBUG
                let t0 = CACurrentMediaTime()
                defer { FeedCellTiming.log("warm", t0) }
                #endif
                let layout = self.warmQueue.removeFirst()
                let cell = self.warmCell
                cell.frame = CGRect(x: 0, y: 0, width: CGFloat(layout.key.width), height: layout.height)
                cell.overrideUserInterfaceStyle = self.collectionView?.traitCollection.userInterfaceStyle ?? .unspecified
                cell.apply(layout, item: self.items[layout.key.item.id], settled: false)
                cell.layoutIfNeeded()
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
                _ = renderer.image { context in cell.layer.render(in: context.cgContext) }
                self.pumpWarmUp()
            }
        }
    }

    private static let emptyKey = FeedRowKey(
        item: FeedItem(id: "", kind: .finished, workspaceID: "", tabID: "", agentName: "", harness: "", workspaceTitle: "", markdown: "",
                       quote: nil, createdAt: .distantPast),
        state: FeedRowState(), width: 0, textSize: ""
    )

    private func widthChanged(_ newWidth: CGFloat) {
        #if DEBUG
        FeedCellTiming.logger.notice("FEEDCELL width \(newWidth, privacy: .public)")
        #endif
        guard newWidth > 0, abs(newWidth - width) > 0.5 else { return }
        width = newWidth
        measureHeader()
        relayoutAll()
    }

    /// The width or the text size changed: every layout is stale. The list keeps showing what it
    /// shows (order, row state); the rows on screen are laid out again once and reconfigured
    /// (applyPending), the rest when they scroll in; the top row stays put and nothing counts as new.
    private func relayoutAll() {
        guard width > 0 else { return }
        pending = pending ?? shownOrder.compactMap { items[$0] }
        relayingOut = !shownOrder.isEmpty
        // Off the layout pass (this runs from layoutSubviews and trait changes).
        guard !applyScheduled else { return }
        applyScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.applyPending() }
        }
    }

    /// A relayout is waiting for its rows (``relayoutAll()``).
    private var relayingOut = false

    // MARK: Row state

    /// `keepsTop`: the person toggled this row (Show more, Show less, a quote, a code block): its top
    /// stays where it is on screen and only what is below it moves.
    private func mutateState(_ id: String, animated: Bool = true, keepsTop: Bool = false, _ change: (inout FeedRowState) -> Void) {
        var state = states[id] ?? FeedRowState()
        change(&state)
        states[id] = state
        refreshRows([id], animated: animated, keepingTopOf: keepsTop ? id : nil)
    }

    /// Lays out `ids` again at once (a row's own state changed) and reconfigures them.
    private func refreshRows(_ ids: [String], animated: Bool, keepingTopOf kept: String? = nil) {
        guard let dataSource, let collectionView else { return }
        let present = ids.filter { shownKeys[$0] != nil && items[$0] != nil }
        guard !present.isEmpty else { return }
        // The new layouts first: a toggled row's anchor depends on whether it grows.
        var keys: [String: FeedRowKey] = [:]
        for id in present {
            guard let item = items[id] else { continue }
            let key = key(for: item)
            if layouts.cached(key) == nil { layouts.store(makeLayout(key), for: key) }
            keys[id] = key
        }
        // A row the person toggled keeps its top where it is, so what they read does not move: anchoring
        // the row after it (as for a row that resized on its own) pushed a growing row's top, and
        // everything above it, up whenever that top was under the bars. A shrinking row whose top is
        // above the screen (Show less at the end of a long body) keeps the row after it instead, so
        // its end stays where the person tapped and its start is not left far above the screen.
        let anchor = jumpingToTop ? nil
            : kept.flatMap { toggledRowAnchor($0) } ?? (syncAtTop() ? nil : visibleAnchor(excluding: Set(present)))
        for (id, key) in keys {
            shownKeys[id] = key
            shownHeights[id] = layouts.cached(key)?.height ?? 1
        }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(present)
        rowsReconfigured += present.count
        // One batch update reconfigures the rows and reads their new heights; animated, the table moves
        // the rows to them (Reduce Motion: at once).
        let animate = animated && !UIAccessibility.isReduceMotionEnabled
        let resize = {
            dataSource.apply(snapshot, animatingDifferences: animate)
            collectionView.performBatchUpdates(nil)
            if let anchor { self.restore(anchor) }
            self.continueJumpToTop()
        }
        if animate { resize() } else { UIView.performWithoutAnimation(resize) }
    }

    private func cell(_ id: String) -> FeedRowCell? {
        guard let indexPath = dataSource?.indexPath(for: id) else { return nil }
        return collectionView?.cellForRow(at: indexPath) as? FeedRowCell
    }

    // MARK: Anchoring

    private struct Anchor { var id: String; var delta: CGFloat }

    /// The first event row on screen and where it starts relative to the scroll offset.
    private func visibleAnchor(excluding: Set<String> = []) -> Anchor? {
        guard let collectionView, let dataSource else { return nil }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let rows = (collectionView.indexPathsForVisibleRows ?? []).filter { $0.section == 1 }.sorted()
        for indexPath in rows {
            let frame = collectionView.rectForRow(at: indexPath)
            guard frame.maxY > top, let id = dataSource.itemIdentifier(for: indexPath), !excluding.contains(id) else { continue }
            return Anchor(id: id, delta: frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    /// The anchor for a row the person toggled (its state already changed): its own top, unless it
    /// shrinks with its top above the screen (then nil: the row after it is kept).
    private func toggledRowAnchor(_ id: String) -> Anchor? {
        guard let collectionView, let indexPath = dataSource?.indexPath(for: id), let item = items[id] else { return nil }
        let frame = collectionView.rectForRow(at: indexPath)
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        guard frame.maxY > visibleTop, frame.minY < visibleBottom else { return nil }
        let newHeight = layouts.cached(key(for: item))?.height ?? frame.height
        if newHeight < frame.height - 0.5, frame.minY < visibleTop - 0.5 { return nil }
        return Anchor(id: id, delta: frame.minY - collectionView.contentOffset.y)
    }

    private func restore(_ anchor: Anchor) {
        guard let collectionView, let indexPath = dataSource?.indexPath(for: anchor.id) else { return }
        collectionView.layoutIfNeeded()
        let frame = collectionView.rectForRow(at: indexPath)
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let y = min(max(frame.minY - anchor.delta, minY), maxY)
        if abs(y - collectionView.contentOffset.y) > 0.25 {
            trace("restore \(Int(collectionView.contentOffset.y))->\(Int(y)) top=\(control.atTop)")
            collectionView.contentOffset.y = y
        }
    }

    // MARK: Commands

    /// DEBUG: what moved the list around a jump to the top, newest last, as the list's
    /// accessibility value (the pill UI tests attach it). Release: nothing.
    private func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
        jumpTrace.append(String(format: "%.2f ", CACurrentMediaTime()) + line())
        if jumpTrace.count > 40 { jumpTrace.removeFirst(jumpTrace.count - 40) }
        collectionView?.accessibilityValue = jumpTrace.joined(separator: "\n")
        #endif
    }

    #if DEBUG
    private var jumpTrace: [String] = []
    private var lastTracedOffset: CGFloat = 0
    #endif

    /// A jump to the top (the "N new" pill) is under way until it lands or the person drags.
    private var jumpingToTop = false {
        didSet { if control.jumpingToTop != jumpingToTop { control.jumpingToTop = jumpingToTop } }
    }

    func scrollToTop(animated: Bool) {
        guard let collectionView else { return }
        let top = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
        // Reduce Motion: the list is at its top at once.
        jumpingToTop = animated && !UIAccessibility.isReduceMotionEnabled && abs(collectionView.contentOffset.y - top.y) > 0.25
        trace("jump from \(Int(collectionView.contentOffset.y)) to \(Int(top.y)) animated=\(jumpingToTop)")
        collectionView.setContentOffset(top, animated: jumpingToTop)
        if !jumpingToTop {
            if collectionView.contentOffset != top { collectionView.contentOffset = top }
            reachedTop()
        }
        // A jump clears the count when it reaches the top (scrollViewDidScroll), so the pill keeps
        // it until then and keeps it when a touch stops the jump on the way.
    }

    /// Whether the list shows its top (within 60 pt), read from the live offset and published to
    /// the screen. Read where it decides something, never from the last scroll callback: a jump's
    /// landing can reach the top with no `scrollViewDidScroll` at the final offset, and a stale
    /// "not at top" made every new event keep the reader's row in place, pushing the list back down
    /// by each event's height right after the pill landed it at the top.
    @discardableResult
    private func syncAtTop() -> Bool {
        guard let collectionView else { return control.atTop }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top < 60
        if top != control.atTop { control.atTop = top }
        if top { reachedTop() }
        return top
    }

    /// The events above have been seen: the pill's count clears.
    private func reachedTop() {
        if control.newAbove != 0 { control.newAbove = 0 }
        store.clearUnseen()
    }

    /// A touch on the list while a jump to the top moves it: the jump stops where it is (as a touch
    /// stops a fling), and the touch is the list's, never the row's that moved under the finger.
    @objc private func touchDuringJump(_ catcher: FeedJumpTouchCatcher) {
        guard catcher.state == .began, let collectionView else { return }
        trace("touch during jump at \(Int(collectionView.contentOffset.y))")
        jumpingToTop = false
        // Within the last stretch (the pill already gone) the jump finishes: it lands at the top.
        let here = control.atTop ? CGPoint(x: 0, y: -collectionView.adjustedContentInset.top) : collectionView.contentOffset
        collectionView.setContentOffset(here, animated: false)
    }

    /// A snapshot applied during a jump to the top can move or stop the animated offset: aim at
    /// the top again so the jump still lands there.
    private func continueJumpToTop() {
        guard jumpingToTop, let collectionView else { return }
        trace("re-aim at \(Int(collectionView.contentOffset.y))")
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        trace("animation end at \(Int(scrollView.contentOffset.y)) jumping=\(jumpingToTop) top=\(control.atTop)")
        defer { syncAtTop() }
        guard jumpingToTop else { return }
        jumpingToTop = false
        // Land exactly at the top, whatever changed while the list moved.
        let top = -scrollView.adjustedContentInset.top
        if abs(scrollView.contentOffset.y - top) > 0.25 { scrollView.contentOffset.y = top }
    }

    func scrollTo(id: String, animated: Bool) {
        guard let collectionView, let indexPath = dataSource?.indexPath(for: id) else { return }
        let frame = collectionView.rectForRow(at: indexPath)
        // The row's top under the bars (scrollToItem(.top) ignores the safe area's top inset).
        let maxY = max(-collectionView.adjustedContentInset.top,
                       collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let y = min(frame.minY - collectionView.adjustedContentInset.top, maxY)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    // MARK: Cells

    /// Exact heights for the rows the table shows: the header's measured height, each row's from
    /// its layout (laid out here if prefetch did not get to it). Other rows hold the estimate.
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.section != 0 else {
            return indexPath.row == 0 ? headerHeight : FeedPinnedLabelCell.height(FeedPinnedLabelCell.font(styles))
        }
        heightQueries += 1
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return 1 }
        if let height = shownHeights[id] { return height }
        guard let layout = layout(for: id) else { return Self.estimatedRowHeight }
        shownHeights[id] = layout.height
        return layout.height
    }

    // MARK: Prefetch

    /// Rows a prefetch is laying out now.
    private var prefetching: Set<String> = []

    /// UIKit's prefetch (about a screen ahead in the scroll direction) is the list's overscan: those
    /// rows are laid out off the main thread, so they scroll in with their layout ready.
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        guard let dataSource else { return }
        let keys = indexPaths.filter { $0.section != 0 }.compactMap { dataSource.itemIdentifier(for: $0) }
            .filter { !prefetching.contains($0) && shownHeights[$0] == nil }
            .compactMap { id in items[id].map { key(for: $0) } }
            .filter { layouts.cached($0) == nil }
        guard !keys.isEmpty else { return }
        prefetching.formUnion(keys.map(\.item.id))
        rowsLaidOut += keys.count
        let styles = styles, scale = scale
        queue.async { [weak self] in
            let built = keys.map { FeedRowLayout.make($0, styles: styles, scale: scale) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for layout in built {
                        let id = layout.key.item.id
                        self.prefetching.remove(id)
                        // A row that changed meanwhile is laid out when it shows.
                        guard let item = self.items[id], self.key(for: item) == layout.key else { continue }
                        self.layouts.store(layout, for: layout.key)
                    }
                }
            }
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // A reused cell may have missed redraws (a read flag, the minute) while off screen.
        if let cell = cell as? FeedRowCell, let id = cell.layout?.key.item.id, let item = items[id] {
            if cell.shownRead != item.isRead { cell.redraw(item) }
            if CACurrentMediaTime() - cell.timeDrawnAt > 30 { cell.refreshTime() }
        }
        // Near the end: the events that left memory come back from disk before the person gets there.
        if indexPath.section != 0, store.olderOnDisk > 0,
           indexPath.row >= tableView.numberOfRows(inSection: indexPath.section) - Self.loadOlderLead {
            store.loadOlder()
        }
        #if DEBUG
        if FeedCellTiming.enabled { FeedCellTiming.logger.notice("FEEDCELL willDisplay \(indexPath.row, privacy: .public) y=\(Int(tableView.contentOffset.y), privacy: .public)") }
        #endif
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Back at the top: what scrolling brought back from disk goes back there.
        if syncAtTop(), !scrollView.isTracking { store.restoreWindow() }
        #if DEBUG
        // A jump moves only toward the top: a step away from it is something else moving the list.
        if jumpingToTop, scrollView.contentOffset.y > lastTracedOffset + 0.5 {
            trace("moved away \(Int(lastTracedOffset))->\(Int(scrollView.contentOffset.y)) size=\(Int(scrollView.contentSize.height))")
        }
        lastTracedOffset = scrollView.contentOffset.y
        #endif
        // At the top exactly: the jump is over, whether or not its animation reported its end.
        if jumpingToTop, abs(scrollView.contentOffset.y + scrollView.adjustedContentInset.top) <= 0.25 {
            trace("reached top")
            jumpingToTop = false
        }
        markMoving()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        trace("drag at \(Int(scrollView.contentOffset.y)) jumping=\(jumpingToTop)")
        // The person took over: a jump to the top in flight ends where they caught it.
        jumpingToTop = false
        #if DEBUG
        // G-04: a finger-driven scroll is one frame-interval window (CMUX_MOBILE_FRAMELOG=1).
        if FeedStressRig.shared.config.autoscrollPasses == nil { FrameIntervalLog.shared.begin("feed-scroll") }
        #endif
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollEnded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollEnded() }

    private func scrollEnded() {
        #if DEBUG
        if FeedStressRig.shared.config.autoscrollPasses == nil { FrameIntervalLog.shared.end() }
        #endif
    }

    /// The Feed moved: web bodies wait (placeholders) until it has been still for a moment.
    private func markMoving() {
        rowsSettled = false
        lastScroll = CACurrentMediaTime()
        guard settleTask == nil else { return }
        settleTask = Task { @MainActor [weak self] in
            // A bounded debounce, not synchronization: 150 ms without a scroll event is "settled".
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let view = self.collectionView else { return }
                if CACurrentMediaTime() - self.lastScroll >= 0.15, !view.isTracking, !view.isDecelerating { break }
            }
            guard let self else { return }
            self.settleTask = nil
            self.rowsSettled = true
            self.visibleCells.forEach { $0.scrollSettled() }
        }
    }

    // MARK: Swipe actions

    /// The row's trailing actions, UIKit's own: the outermost is the full swipe.
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section != 0, let id = dataSource?.itemIdentifier(for: indexPath), !FeedStacks.isFold(id), let item = items[id] else {
            return UISwipeActionsConfiguration(actions: [])
        }
        let context = context
        return item.swipeActions(store: store, open: { context.open(item) }).configuration
    }

    /// No leading actions: a rightward swipe from the leading edge opens the team drawer.
    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        UISwipeActionsConfiguration(actions: [])
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
        openRow = id
        registerOpenRow(in: tableView)
    }

    /// Tells the drawer a row is open: a rightward swipe closes it and never opens the drawer (Mail).
    /// A swipe on the table is UIKit's: its own swipe recognizer drags the row closed under the
    /// finger, so closing it here too ran a second, animated close against that one, and the row
    /// jumped up a row's height for a moment. The drawer closes it only for a swipe that starts off
    /// the table. Left to UIKit, the row stays registered (the drawer drops a closer it called): a
    /// short drag springs it back open, and the row must still count as open.
    private func registerOpenRow(in tableView: UITableView) {
        RowSwipeActions.shared.setOpen(registrationKey, close: { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            guard !tableView.isTracking else { return self.registerOpenRow(in: tableView) }
            tableView.setEditing(false, animated: true)
        })
    }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        // UIKit may end the row it closed after it began the next one: only the open row's end counts.
        let id = indexPath.flatMap { dataSource?.itemIdentifier(for: $0) }
        guard id == nil || id == openRow else { return }
        openRow = nil
        RowSwipeActions.shared.setOpen(registrationKey, close: nil)
    }

    /// The row whose actions are open (UIKit keeps one open at a time).
    private var openRow: String?

    private var registrationKey: String { "feed.\(ObjectIdentifier(swipe))" }

    private func observeSwipe() {
        withObservationTracking {
            _ = swipe.demoSerial
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.swipeChanged()
                self.observeSwipe()
            }
        }
    }

    private var lastDemoSerial = 0

    private func swipeChanged() {
        guard swipe.demoSerial != lastDemoSerial else { return }
        lastDemoSerial = swipe.demoSerial
        // UIKit opens a row's actions only under a finger; the demo performs the action itself.
        if let (id, action) = swipe.demoPerform, let item = items[id] {
            let context = context
            item.swipeActions(store: store, open: { context.open(item) }).first { $0.id == action }?.action()
        }
    }

    // MARK: Row actions

    func rowOpen(_ id: String) {
        guard let item = items[id] else { return }
        context.open(item)
    }

    func rowToggleExpanded(_ id: String) {
        mutateState(id, keepsTop: true) { $0.expanded.toggle() }
    }

    func rowToggleQuote(_ id: String) {
        mutateState(id, keepsTop: true) { $0.quoteExpanded.toggle() }
    }

    func rowToggleReply(_ id: String) {
        let opening = !(states[id]?.replying ?? false)
        mutateState(id) { $0.replying = opening }
        guard opening, let indexPath = dataSource?.indexPath(for: id) else { return }
        collectionView?.scrollToRow(at: indexPath, at: .bottom, animated: true)
        cell(id)?.focusComposer()
    }

    func rowReplyDraft(_ id: String, _ text: String) {
        guard states[id]?.replyDraft != text else { return }
        var state = states[id] ?? FeedRowState()
        let before = items[id].map { key(for: $0) }
        state.replyDraft = text
        states[id] = state
        // Only a new line count changes the row; otherwise the field grows nothing.
        guard let item = items[id], let before, let old = layouts.cached(before) else { return refreshRows([id], animated: false) }
        let layout = makeLayout(key(for: item))
        layouts.store(layout, for: layout.key)
        if abs(layout.height - old.height) > 0.25 || (layout.composer?.height != old.composer?.height) {
            refreshRows([id], animated: false)
        } else {
            shownKeys[id] = layout.key
            shownHeights[id] = layout.height
            cell(id)?.apply(layout, item: items[id], settled: rowsSettled)
        }
    }

    func rowSendReply(_ id: String) {
        guard let item = items[id] else { return }
        let text = (states[id]?.replyDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if item.opensTerminal {
            // Typed into the terminal's agent on its Mac; the state (sending, sent, refused) lives on the item.
            mutateState(id) { $0.replyFailure = nil; $0.replying = false; $0.replyDraft = "" }
            let route = FeedRouting.shared.replyToTerminal
            store.replyToTerminal(id, text: text) { item, text in
                guard let route else { return "Open the terminal to reply." }
                return await route(item, text)
            }
            return
        }
        let sent = FeedRouting.shared.sendPrompt?(item, text) ?? .failed("Open this chat to reply.")
        switch sent {
        case .sent(let chat):
            store.reply(id, text: text)
            if replyChats[id] !== chat {
                replyChats[id] = chat
                observeReplyChat(id, chat)
            }
            mutateState(id) { $0.replyFailure = chat.clientError; $0.replying = false; $0.replyDraft = "" }
        case .failed(let reason):
            mutateState(id) { $0.replyFailure = reason; $0.replying = false; $0.replyDraft = "" }
        }
        CmuxMobileTheme.standard.haptics.impact(.light, intensity: 1)
    }

    /// The chat the reply went to: its refusal (the Mac's reason) shows under the reply.
    private func observeReplyChat(_ id: String, _ chat: AgentChatStore) {
        withObservationTracking { _ = chat.clientError } onChange: { [weak self, weak chat] in
            Task { @MainActor in
                // The chain ends when the row leaves the list or its chat changes.
                guard let self, let chat, self.replyChats[id] === chat, self.items[id] != nil else { return }
                if self.states[id]?.replyFailure != chat.clientError { self.mutateState(id, animated: false) { $0.replyFailure = chat.clientError } }
                self.observeReplyChat(id, chat)
            }
        }
    }

    func rowCopy(_ id: String) {
        guard let item = items[id] else { return }
        UIPasteboard.general.string = item.markdown
        if states[id]?.copied != true { CmuxMobileTheme.standard.haptics.impact(.light, intensity: 0.7) }
        mutateState(id, animated: false) { $0.copied = true }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.mutateState(id, animated: false) { $0.copied = false }
        }
    }

    func rowCopyCommand(_ id: String) {
        guard let item = items[id], case .permission(let request) = item.kind else { return }
        UIPasteboard.general.string = request.toolCall.command
        CmuxMobileTheme.standard.haptics.impact(.light, intensity: 0.7)
    }

    func rowShare(_ id: String, from source: UIView) {
        guard let item = items[id], let host = collectionView?.window?.rootViewController else { return }
        var top = host
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        let sheet = UIActivityViewController(activityItems: [item.markdown], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        top.present(sheet, animated: true)
    }

    func rowRespond(_ id: String, optionID: String) {
        guard let item = items[id], case .permission(let request) = item.kind,
              let option = request.phoneOptions.first(where: { $0.id == optionID }) else { return }
        store.respond(id, option: option)
    }

    func rowDecline(_ id: String) {
        store.decline(id)
    }

    func rowQuestion(_ id: String, _ input: AgentQuestionCardState.Input) {
        guard let item = items[id], case .question(let question) = item.kind, question.isPending else { return }
        var state = states[id]?.question
            ?? QuestionDraftStore.shared.draft(for: question.id)?.restore(into: question)
            ?? AgentQuestionCardState(question: question)
        let effect = state.send(input)
        switch effect {
        case .submit(let answer):
            // The card state and draft stay until the question stops pending (a refused answer
            // brings the card back with the person's picks); applyPending clears them then.
            QuestionDraftStore.shared.save(QuestionDraft(state), for: question.id)
            mutateState(id, animated: false) { $0.question = state }
            store.answer(id, answer: answer)
        default:
            QuestionDraftStore.shared.save(QuestionDraft(state), for: question.id)
            mutateState(id) { $0.question = state }
            if effect == .beginOtherEditing { cell(id)?.focusQuestionOther() }
            if effect == .resign { cell(id)?.resignQuestionOther() }
        }
    }

    func rowCodeExpand(_ id: String) {
        mutateState(id, keepsTop: true) { $0.codeExpanded = true }
    }

    func rowWebHeight(_ id: String, _ height: CGFloat) {
        guard let current = states[id]?.webHeight.map({ CGFloat($0) }) ?? Optional(layout(for: id).map { $0.body.fullHeight } ?? 0),
              abs(current - height) > 0.5 else { return }
        mutateState(id, animated: false) { $0.webHeight = Double(height) }
    }

    func rowMenu(_ id: String) -> UIMenu {
        guard let item = items[id] else { return UIMenu() }
        let store = store, context = context
        var children: [UIMenuElement] = [
            UIAction(title: "Open Tab", image: UIImage(systemName: "arrow.up.right.square")) { _ in context.open(item) },
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = item.markdown },
        ]
        // Everything the trailing swipe leaves out lives here (SPEC swipe rules).
        children.append(item.isRead
            ? UIAction(title: "Mark as Unread", image: UIImage(systemName: "envelope.badge")) { _ in store.markUnread(item.id) }
            : UIAction(title: "Mark as Read", image: UIImage(systemName: "envelope.open")) { _ in store.markRead(item.id) })
        children.append(UIAction(title: "Done", image: UIImage(systemName: "checkmark")) { _ in store.markDone(item.id) })
        children.append(UIAction(title: "Mute This Workspace", image: UIImage(systemName: "bell.slash")) { _ in
            _ = store.mutedWorkspaces.insert(item.workspaceID)
        })
        return UIMenu(title: item.createdAt.formatted(.dateTime.weekday(.wide).hour().minute()), options: .displayInline, children: children)
    }

    // MARK: Demo driver

    #if DEBUG
    func demo(_ command: DemoDirector.Command) {
        switch command {
        case .feedExpand(let id):
            mutateState(id) { $0.expanded = true }
        case .feedStack(let id, let expanded):
            setStack(head: id, expanded: expanded)
        case .feedReply(let id, let text):
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mutateState(id) { $0.replying = true }
                try? await Task.sleep(for: .milliseconds(500))
                var typed = ""
                for character in text {
                    typed.append(character)
                    self.rowReplyDraft(id, typed)
                    try? await Task.sleep(for: .milliseconds(35))
                }
                try? await Task.sleep(for: .milliseconds(300))
                self.rowSendReply(id)
            }
        case .answerQuestion(let questionID, let picks):
            guard let item = items.values.first(where: { if case .question(let q) = $0.kind { return q.id == questionID }; return false }),
                  case .question(let question) = item.kind else { return }
            let id = item.id
            Task { @MainActor [weak self] in
                for (index, ids) in picks.enumerated() where question.items.indices.contains(index) {
                    let entry = question.items[index]
                    try? await Task.sleep(for: .milliseconds(700))
                    for pick in ids {
                        if let row = entry.options.firstIndex(where: { $0.id == pick }) {
                            self?.rowQuestion(id, .click(row: row))
                            try? await Task.sleep(for: .milliseconds(600))
                        }
                    }
                    if entry.multiSelect { self?.rowQuestion(id, index == question.items.count - 1 ? .submit : .nextItem) }
                }
            }
        default:
            break
        }
    }
    #endif
}

/// The pinned group's label under the chips: "Needs you · 2", in the chips' text style, on the
/// rows' 16 pt leading edge. UIKit only, like the rows; its height is its font's line plus fixed
/// padding, so nothing is measured.
final class FeedPinnedLabelCell: UITableViewCell {
    private let label = UILabel()

    static func font(_ styles: NativeTextStyles) -> UIFont { styles.font(.subheadline, weight: .medium) }
    static func height(_ font: UIFont) -> CGFloat { ceil(font.lineHeight) + 12 }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .cmuxMobileBackground
        label.textColor = .secondaryLabel
        label.accessibilityTraits = .header
        label.accessibilityIdentifier = "feed.needsYouLabel"
        contentView.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(count: Int, font: UIFont) {
        label.font = font
        label.text = FeedPinnedGroup.title(count)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds, line = ceil(label.font.lineHeight)
        // 4 pt under the chips' 44 pt row, 8 pt above the first ask.
        label.frame = CGRect(x: 16, y: 4, width: max(0, bounds.width - 32), height: line)
    }
}

/// The Feed's diffable source. A diffable table source answers no to
/// `canEditRowAt` by default, which turns off every swipe action: event rows
/// say yes (their actions are the delegate's trailing configuration), the
/// header row no.
final class FeedTableDataSource: UITableViewDiffableDataSource<FeedListController.Section, String> {
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        // A stack's fold line has no swipe actions.
        indexPath.section != 0 && itemIdentifier(for: indexPath).map { !FeedStacks.isFold($0) } ?? true
    }
}
#endif
