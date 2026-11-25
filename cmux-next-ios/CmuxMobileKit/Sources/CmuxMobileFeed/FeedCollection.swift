#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileMarkdown
import CmuxMobileModel
import CmuxSpinner
import Observation
import OSLog
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
/// keyed by event id. Each row's layout (`FeedRowLayout`) is computed off
/// the main thread, kept until its event or row state changes, and gives the
/// table exact heights, so scrolling a row in costs placing reused views and
/// nothing else. A table (not a collection view with its own layout) so the
/// rows get UIKit's own trailing swipe actions (`UIContextualAction`): the
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
    /// A part of the header that comes and goes while the Feed is read (the working-now strip):
    /// when it changes, the header's new height animates at the top of the list, and the
    /// reader's rows stay where they are further down.
    var headerAnimatedPart: AnyHashable = AnyHashable(false)

    func makeCoordinator() -> FeedListController {
        FeedListController(context: context, swipe: swipe, control: control)
    }

    func makeUIViewController(context: Context) -> FeedCollectionController {
        FeedCollectionController(collection: context.coordinator.makeView())
    }

    func updateUIViewController(_ controller: FeedCollectionController, context: Context) {
        context.coordinator.update(items: items, header: header, signature: headerSignature, headerContent: headerContent,
                                   animatedPart: headerAnimatedPart)
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
    /// The list left or joined a window (the spare's timer stops when it leaves).
    var onWindowChange: ((Bool) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window != nil)
    }
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
final class FeedListController: NSObject, UITableViewDelegate, FeedRowCellDelegate {
    enum Section: Hashable { case header, events }
    static let headerID = "feed.header"
    /// The pinned group's label ("Needs you · 2"), the header section's second row while the
    /// whole Feed has open asks: under the chips, above the first ask.
    static let pinnedLabelID = "feed.needs-you-label"
    /// The most rows that travel at once when asks leave or join the pinned group; more is a rebuild.
    static let pinnedMoveLimit = 4
    /// How many rows before the end the next page of spilled events is read.
    static let loadOlderLead = 30

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
    /// FEED-15: rows that arrived while the person dragged or the list decelerated wait for rest
    /// (one apply then, with the reader's row kept in place): a correction set while UIKit moves the
    /// offset itself is undone by the gesture or the deceleration, and the row being read jumps.
    private var heldUntilRest = false
    /// The held rows the pill counts now (moved into its count by the apply at rest).
    private var heldCounted = 0
    /// A header re-measure that came while the list moved off the top: done at rest.
    private var headerHeld: Bool?
    /// Layouts computed off the main thread, one batch at a time.
    private let queue = DispatchQueue(label: "dev.cmux.mobile.feed-layout", qos: .userInitiated)
    private var batchInFlight = false
    private var header = AnyView(EmptyView())
    private var headerSignature: AnyHashable?
    private var headerContent: AnyHashable?
    private var headerAnimatedPart: AnyHashable?
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
        // Exact heights from the row layouts, never estimates: the table sums them as the old layout did.
        view.estimatedRowHeight = 0
        view.estimatedSectionHeaderHeight = 0
        view.estimatedSectionFooterHeight = 0
        view.sectionHeaderHeight = 0
        view.sectionFooterHeight = 0
        view.delegate = self
        view.register(UITableViewCell.self, forCellReuseIdentifier: Self.headerID)
        view.register(FeedPinnedLabelCell.self, forCellReuseIdentifier: Self.pinnedLabelID)
        view.register(FeedFoldCell.self, forCellReuseIdentifier: FeedFoldCell.reuseID)
        // Row cells are not registered: the provider takes one from the reuse pool, else the spare
        // made before the first scroll (`spare`), else a new one.
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
        view.onWindowChange = { [weak self] inWindow in
            guard let self else { return }
            if inWindow { self.scheduleSpare() } else { self.cancelSpareTimer() }
        }

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
                let row = (tableView.dequeueReusableCell(withIdentifier: FeedRowCell.reuseID) as? FeedRowCell)
                    ?? self?.takeSpare(for: id, at: indexPath) ?? self?.newRowCell() ?? FeedRowCell(style: .default, reuseIdentifier: FeedRowCell.reuseID)
                guard let self, let layout = self.layout(for: id) else { return row }
                row.delegate = self
                row.apply(layout, item: self.items[id], settled: self.rowsSettled)
                row.leadsStack = self.stackHeads.contains(id)
                return row
            }
        }
        collectionView = view
        #if DEBUG
        FeedShiftProbe.shared.attach(view)
        #endif
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

    func update(items next: [FeedItem], header: AnyView, signature: AnyHashable, headerContent content: AnyHashable,
                animatedPart: AnyHashable = AnyHashable(false)) {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("update y=\(Int(collectionView?.contentOffset.y ?? 0))", t0) }
        #endif
        self.header = header
        // The first value is the header's first measure, not a part coming or going.
        let partChanged = headerAnimatedPart != nil && headerAnimatedPart != animatedPart
        headerAnimatedPart = animatedPart
        if signature != headerSignature {
            headerSignature = signature
            headerContent = content
            if let view = collectionView, holdsForScroll(view) {
                headerHeld = (headerHeld ?? false) || partChanged
            } else {
                measureHeader(partChanged: partChanged)
            }
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
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func setStack(head: String, expanded: Bool) {
        guard stackHeads.contains(head), control.expandedStacks.contains(head) != expanded else { return }
        if expanded { control.expandedStacks.insert(head) } else { control.expandedStacks.remove(head) }
        stack()
        animatesNextCommit = true
        applyScheduled = true
        applyPending()
    }

    /// `partChanged`: a part of the header came or went while the Feed is read (the working-now
    /// strip). At the top the rows slide to the header's new height (not under Reduce Motion);
    /// further down the reader's first row stays where it is.
    private func measureHeader(partChanged: Bool = false) {
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
        // Any re-measure off the top keeps the reader's row (a refresh error, the sync state, the
        // needs-you chip change the header's height too, not only the working-now strip).
        let anchor = !syncAtTop() && !jumpingToTop ? visibleAnchor() : nil
        headerHeight = height
        reconfigureHeader()
        // The table reads the header's new height.
        if partChanged, anchor == nil, control.atTop, !jumpingToTop, !UIAccessibility.isReduceMotionEnabled {
            collectionView?.performBatchUpdates(nil)
        } else {
            UIView.performWithoutAnimation { collectionView?.performBatchUpdates(nil) }
            if let anchor { restore(anchor) }
        }
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
        let styles = styles, scale = scale
        return layouts.value(for: key) { FeedRowLayout.make(key, styles: styles, scale: scale) }
    }

    private func applyPending() {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("applyPending y=\(Int(collectionView?.contentOffset.y ?? 0))", t0) }
        #endif
        applyScheduled = false
        guard let next = pending, width > 0, let view = collectionView else { return }
        if holdsForScroll(view) {
            if !heldUntilRest { trace("held while scrolling at \(Int(view.contentOffset.y))") }
            heldUntilRest = true
            countHeld(next)
            return
        }
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
        let missing = keys.filter { !unchanged.contains($0.0) && layouts.cached($0.1) == nil }.map(\.1)
        if relayingOut {
            // A width or text size change: wait until every row is laid out again, then reconfigure them all.
            if !missing.isEmpty { computeInBackground(missing); return }
            relayingOut = false
            commit(next, keys: keys, reconfigureAll: true)
            return
        }
        // Rows are laid out off the main thread; the list shows the change once its rows are ready.
        // Only the first screen of a new Feed is laid out here.
        if !missing.isEmpty {
            if shownOrder.isEmpty {
                // The first screen at once; the rest follow.
                let styles = styles, scale = scale
                for key in missing.prefix(10) { layouts.store(FeedRowLayout.make(key, styles: styles, scale: scale), for: key) }
            }
            let still = keys.filter { !unchanged.contains($0.0) && layouts.cached($0.1) == nil }.map(\.1)
            if !still.isEmpty { computeInBackground(still) }
            // Show what is ready only when nothing is shown yet; otherwise wait for the batch.
            guard shownOrder.isEmpty || still.isEmpty else { return }
            let ready = Set(keys.filter { unchanged.contains($0.0) || layouts.cached($0.1) != nil }.map(\.0))
            commit(next.filter { ready.contains($0.id) }, keys: keys.filter { ready.contains($0.0) }, unchanged: unchanged)
            return
        }
        commit(next, keys: keys, unchanged: unchanged)
    }

    private func computeInBackground(_ keys: [FeedRowKey]) {
        guard !batchInFlight else { return }
        batchInFlight = true
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
    private func commit(_ next: [FeedItem], keys: [(String, FeedRowKey)], reconfigureAll: Bool = false, unchanged: Set<String> = []) {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("commit n=\(next.count)", t0) }
        #endif
        guard let dataSource, let collectionView else { return }
        #if DEBUG
        ListApplyProbe.shared.applied("feed")
        #endif
        var plan = FeedListPlan(oldOrder: shownOrder, shown: shownKeys, new: keys, unchanged: unchanged)
        if reconfigureAll { plan.reconfigure = keys.map(\.0).filter { shownKeys[$0] != nil } }
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
        let animated = animatesNextCommit && !UIAccessibility.isReduceMotionEnabled && !reconfigureAll
        animatesNextCommit = false
        // The pinned group (open asks first, the whole Feed only) and its label's count.
        let pinned = FeedPinnedGroup.count(next, filter: store.filter)
        let wasPinned = shownPinned
        guard !plan.isEmpty || pinned != wasPinned || dataSource.snapshot().numberOfSections == 0 else { return }
        // A jump to the top in flight keeps no anchor: restoring one would set the offset and cut the
        // jump's animation short wherever it was (the pill then left the person mid-list).
        // A fold line's toggle keeps no anchor either: its rows come and go below it, under the table's animation.
        var anchor = syncAtTop() || jumpingToTop || animated ? nil : visibleAnchor()
        let previousOrder = shownOrder
        let previousSet = shownSet
        shownOrder = next.map(\.id)
        if plan.orderChanged { shownSet = Set(shownOrder) }
        if plan.orderChanged || reconfigureAll {
            shownKeys = Dictionary(keys, uniquingKeysWith: { first, _ in first })
        }
        // Each changed row's height, from the layout of the key it is shown with.
        var heightChanged = false
        for (id, key) in keys where !unchanged.contains(id) || shownHeights[id] == nil {
            shownKeys[id] = key
            let height = layouts.cached(key)?.height ?? 1
            if let old = shownHeights[id], abs(old - height) > 0.25 { heightChanged = true }
            shownHeights[id] = height
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
        applyCount += 1
        // The row kept in place is never one that travels: the reader stays with the asks still open.
        if !travelling.isEmpty, anchor.map({ travelling.contains($0.id) }) == true { anchor = visibleAnchor(excluding: travelling) }
        // At the top the answered ask slides to its place; off the top it moves at once with the
        // reader's row kept (an animated move while the offset is restored is a visible jump, FEED-15).
        if !travelling.isEmpty, anchor == nil, !UIAccessibility.isReduceMotionEnabled, collectionView.window != nil {
            // The rows show their new state where they are (an answered card, at once), then the
            // table moves the answered ask to its place in time and closes the gap it left.
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
        scheduleSpare()
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

    // MARK: The first scroll's spare cell

    /// One row cell built before the first scroll, filled with the list's heaviest row (a
    /// permission card: its command block, quote and option buttons) and parked in the table off
    /// screen, so its layers are drawn once. The first scroll needs one more cell than the screen
    /// shows before any cell leaves it for the reuse pool; that cell was a new one, built and drawn
    /// for the first time inside one frame's commit, the frame the Feed dropped at base and head
    /// (profiles 4d3840dc/e01a6632: init 2, apply 4, layout 1-2, first draw 3, backing store 2 ms).
    private var spare: FeedRowCell?
    private var spareScheduled = false
    /// Spares built and taken, and row cells the provider had to make itself (tests).
    private(set) var sparesMade = 0
    private(set) var sparesTaken = 0
    private(set) var newCells = 0
    /// New cells the provider made before the spare was taken (tests: none once it is parked).
    private(set) var newCellsBeforeSpare = 0
    /// The spare once a row took it (tests: it shows that row, whatever row it was built with).
    private(set) weak var spareGiven: FeedRowCell?
    /// The identifier a parked spare answers to (no row has it).
    static let parkedSpareID = "feed.spare.parked"
    #if DEBUG
    /// The visible-spare mutant (FeedParkedSpareUITests) keeps its spare this long after the plant.
    static let mutantHold: CFTimeInterval = 4
    private var mutantHoldUntil: CFTimeInterval = 0
    /// The visible-spare mutant planted its spare: only then are takes traced with their asker.
    private var mutantPlanted = false
    #endif

    /// The parked spare and its holder (tests: hidden from accessibility, off screen, not in the table).
    var parkedSpare: FeedRowCell? { spare }
    var parkedHolder: UIView? { parkHolder }
    /// How long the list must have been still before the spare is built (one idle build).
    static let spareStillness: CFTimeInterval = 0.5

    private func newRowCell() -> FeedRowCell {
        newCells += 1
        if sparesTaken == 0, spare != nil { newCellsBeforeSpare += 1 }
        return FeedRowCell(style: .default, reuseIdentifier: FeedRowCell.reuseID)
    }

    /// The off-screen holder the spare waits in (hidden from accessibility and touches).
    private var parkHolder: UIView?

    private func sparePark(beside view: UIView) -> UIView {
        if let parkHolder, parkHolder.superview != nil { return parkHolder }
        let holder = UIView()
        holder.isUserInteractionEnabled = false
        holder.accessibilityElementsHidden = true
        holder.isAccessibilityElement = false
        holder.clipsToBounds = false
        (view.superview ?? view).addSubview(holder)
        parkHolder = holder
        return holder
    }

    private func takeSpare(for id: String, at indexPath: IndexPath) -> FeedRowCell? {
        guard let cell = spare else { return nil }
        #if DEBUG
        // Under the visible-spare mutant only (never on a measured path: a stack's symbols cost
        // milliseconds on the frame that needs the cell), who asked goes in the trace: the row,
        // whether it is on screen, whether an accessibility walk asked (spare-ui-4 d0b40ace: the
        // planted spare went 60 ms after it was made, and the trace could not say to what).
        var asker: String?
        if mutantPlanted {
            let onScreen = collectionView.map { $0.rectForRow(at: indexPath).intersects($0.bounds) } ?? false
            let axWalk = Thread.callStackSymbols.contains { $0.contains("Accessibility") || $0.contains("AXRuntime") }
            asker = "row=\(indexPath.row) id=\(id) onScreen=\(onScreen) ax=\(axWalk)"
            if CACurrentMediaTime() < mutantHoldUntil {
                trace("spare held (mutant) " + (asker ?? ""))
                return nil
            }
        }
        #endif
        spare = nil
        cell.removeFromSuperview()
        parkHolder?.removeFromSuperview()
        parkHolder = nil
        cell.prepareForReuse()
        sparesTaken += 1
        #if DEBUG
        if let asker { trace("spare taken " + asker) } else { trace("spare taken") }
        #else
        trace("spare taken")
        #endif
        spareGiven = cell
        return cell
    }

    /// Builds the spare once the list has rows and has been still `spareStillness` (never while it
    /// moves); one build for the Feed's life.
    private func scheduleSpare() {
        guard spare == nil, sparesMade == 0, !spareScheduled, !shownOrder.isEmpty else { return }
        spareScheduled = true
        // A run-loop timer in the common modes, not a task: code that spins the run loop from
        // inside a main-queue block (a test host, a modal) never drains the main queue (green-16:
        // the spare was never built in the unit host).
        // The stillness still to wait (at least 0.1 s): during a long scroll the timer fires about
        // once per stillness period, never in a tight loop.
        let wait = max(0.1, Self.spareStillness - (CACurrentMediaTime() - lastScroll))
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.spareTimerFired() }
        }
        spareTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var spareTimer: Timer?

    /// The Feed left the window, or its controller goes: no spare build is left pending.
    private func cancelSpareTimer() {
        spareTimer?.invalidate()
        spareTimer = nil
        spareScheduled = false
    }

    isolated deinit {
        spareTimer?.invalidate()
    }

    private func spareTimerFired() {
        spareTimer = nil
        spareScheduled = false
        guard let view = collectionView, view.window != nil, !view.isTracking, !view.isDecelerating,
              CACurrentMediaTime() - lastScroll >= Self.spareStillness, !jumpingToTop, !rowAnimating(in: view) else {
            trace("spare deferred window=\(collectionView?.window != nil) still=\(Int((CACurrentMediaTime() - lastScroll) * 1000)) animating=\(collectionView.map(rowAnimating(in:)) ?? false)")
            scheduleSpare()
            return
        }
        buildSpare(in: view)
    }

    /// A row on screen animates from the main thread (a UIKit view animation in flight: a row
    /// growing, a swipe settling, an insert). The rows' spinners turn in the render server (a
    /// Core Animation rotation), which main-thread work does not stop, so they do not count.
    private func rowAnimating(in view: UITableView) -> Bool {
        func animating(_ layer: CALayer) -> Bool {
            if let keys = layer.animationKeys(), keys.contains(where: { $0 != CmuxSpinnerLayer.turnKey }) { return true }
            return layer.sublayers?.contains(where: animating) ?? false
        }
        return view.visibleCells.contains { animating($0.layer) }
    }

    private func buildSpare(in view: UITableView) {
        // The heaviest row the list holds: a permission card with its command, else the tallest.
        var best: FeedRowLayout?
        var question: FeedRowLayout?
        var permission = false
        for id in shownOrder.prefix(200) {
            // A fold line is its own cell (FeedFoldCell), never a row cell's shape.
            guard let key = shownKeys[id], let layout = layouts.cached(key), layout.fold == nil else { continue }
            if case .question = key.item.kind, question == nil { question = layout }
            if case .permission = key.item.kind, !permission {
                best = layout
                permission = true
            } else if !permission, layout.height > (best?.height ?? 0) {
                best = layout
            }
            if permission, question != nil { break }
        }
        guard let layout = best else { return }
        #if DEBUG
        let t0 = CACurrentMediaTime()
        #endif
        let cell = FeedRowCell(style: .default, reuseIdentifier: FeedRowCell.reuseID)
        cell.delegate = self
        // A question card's parts too (its option rows, field and buttons are built on first use:
        // profile db0af69e, the first question row cost 12-14 ms of one frame), then the
        // permission card it is shown with.
        if let question {
            cell.frame = CGRect(x: 0, y: 0, width: CGFloat(question.key.width), height: question.height)
            cell.apply(question, item: items[question.key.item.id], settled: false)
            cell.layoutIfNeeded()
        }
        cell.frame = CGRect(x: 0, y: 0, width: CGFloat(layout.key.width), height: layout.height)
        cell.apply(layout, item: items[layout.key.item.id], settled: false)
        // Parked beside the table, not in it (a table lays its own subviews out as rows, and they
        // stay accessibility elements: FeedParkedSpareUITests saw one at y 1419): in a holder off
        // the window's bounds, hidden from accessibility and touches, its layers drawn at the next
        // commit as any view in the window.
        // While parked it answers to its own identifier, which no row has: a UI test that finds it
        // has found a parked spare (the row that takes it sets its own in `apply`).
        cell.accessibilityIdentifier = Self.parkedSpareID
        let holder = sparePark(beside: view)
        holder.frame = CGRect(x: -CGFloat(layout.key.width) - 1000, y: 0, width: CGFloat(layout.key.width), height: layout.height)
        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_SPARE_MUTANT"] == "visible" {
            // Red for FeedParkedSpareUITests: the way parking could go wrong, the holder on screen
            // over the rows with accessibility on.
            // In the window itself (its table's SwiftUI host may not list a plain subview), so the
            // UI check's power is measured against the most visible place a spare could end up.
            if let window = view.window { window.addSubview(holder) }
            holder.frame = CGRect(x: 0, y: 200, width: CGFloat(layout.key.width), height: layout.height)
            holder.accessibilityElementsHidden = false
            // The plant stays planted until the UI test's first screenshot (12 s after launch): a
            // row cell asked for in its first seconds gets a new cell instead (spare-ui-4: one
            // asked 60 ms after the plant, so the screenshot showed nothing to catch). The test
            // checks from the trace that the take came after its screenshot.
            mutantPlanted = true
            mutantHoldUntil = CACurrentMediaTime() + Self.mutantHold
        }
        #endif
        holder.addSubview(cell)
        cell.layoutIfNeeded()
        spare = cell
        sparesMade += 1
        trace("spare made in \(String(describing: type(of: holder.superview!)))")
        #if DEBUG
        if FeedStressRig.shared.config.isActive {
            // The build's time, and the frame intervals right after it (its first draw lands in the
            // next commit): whether the idle build cost a drawn frame.
            let ms = (CACurrentMediaTime() - t0) * 1000
            var last: CFTimeInterval?
            var intervals: [Double] = []
            var token: FrameClock.Token?
            token = FrameClock.shared.subscribe { tick in
                if let last { intervals.append((tick.timestamp - last) * 1000) }
                last = tick.timestamp
                guard intervals.count >= 4, let done = token else { return }
                FrameClock.shared.unsubscribe(done)
                Logger(subsystem: "dev.cmux.mobile", category: "frames").notice(
                    "FRAMELOG list-stress feed-spare made=1 ms=\(ms, format: .fixed(precision: 2), privacy: .public) next_frames_ms=\(intervals.map { String(format: "%.1f", $0) }.joined(separator: ","), privacy: .public)")
            }
        }
        #endif
    }
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
                // A frame's share at most (profile db0af69e: the queue drained back to back, 74 ms of
                // one frame and 17 of the next, right after the Feed came to rest): items until the
                // budget is spent, the rest at the next frame.
                let start = self.warmClock()
                while !self.warmQueue.isEmpty, self.warmClock() - start < Self.warmBudget {
                    self.warmOne()
                    self.warmItemsDone += 1
                    self.warmItemHook?()
                }
                self.warmBatches += 1
                guard !self.warmQueue.isEmpty else { return }
                self.warmScheduled = true
                var token: FrameClock.Token?
                token = FrameClock.shared.subscribe { [weak self] _ in
                    if let token { FrameClock.shared.unsubscribe(token) }
                    token = nil
                    self?.warmScheduled = false
                    self?.pumpWarmUp()
                }
            }
        }
    }

    /// Main-thread time the warm-up takes per frame (seconds).
    static let warmBudget: CFTimeInterval = 0.004
    /// Warm-up passes run, one per frame at most (tests).
    private(set) var warmBatches = 0
    /// Warm-up items drawn, the clock the budget reads, and a hook after each item (tests give each
    /// item a fixed cost on a fake clock).
    private(set) var warmItemsDone = 0
    var warmClock: () -> CFTimeInterval = { CACurrentMediaTime() }
    var warmItemHook: (() -> Void)?
    var warmQueueCount: Int { warmQueue.count }

    private func warmOne() {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("warm", t0) }
        #endif
        let layout = warmQueue.removeFirst()
        let cell = warmCell
        cell.frame = CGRect(x: 0, y: 0, width: CGFloat(layout.key.width), height: layout.height)
        cell.overrideUserInterfaceStyle = collectionView?.traitCollection.userInterfaceStyle ?? .unspecified
        cell.apply(layout, item: items[layout.key.item.id], settled: false)
        cell.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        _ = renderer.image { context in cell.layer.render(in: context.cgContext) }
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
    /// shows (order, row state) while the rows are laid out again: the visible ones here, the rest off
    /// the main thread; then every row is reconfigured at once, and nothing counts as new.
    private func relayoutAll() {
        guard width > 0 else { return }
        let pendingItems = pending ?? shownOrder.compactMap { items[$0] }
        pending = pendingItems
        let keys = pendingItems.map { key(for: $0) }
        let styles = styles, scale = scale
        let visible = Set(collectionView?.indexPathsForVisibleRows?.compactMap { dataSource?.itemIdentifier(for: $0) } ?? [])
        for key in keys where visible.contains(key.item.id) || (visible.isEmpty && keys.firstIndex(of: key).map { $0 < 10 } == true) {
            layouts.store(FeedRowLayout.make(key, styles: styles, scale: scale), for: key)
        }
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
            if layouts.cached(key) == nil { layouts.store(FeedRowLayout.make(key, styles: styles, scale: scale), for: key) }
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
            #if DEBUG
            FeedShiftProbe.shared.correcting { collectionView.contentOffset.y = y }
            #else
            collectionView.contentOffset.y = y
            #endif
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
        // The true top only (FEED-15): a reader a few points below it keeps their row when rows arrive.
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top <= 0.5
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

    /// Exact heights: the header's measured height, each row's from its layout.
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.section != 0 else {
            return indexPath.row == 0 ? headerHeight : FeedPinnedLabelCell.height(FeedPinnedLabelCell.font(styles))
        }
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return 1 }
        return shownHeights[id] ?? 1
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
        #if DEBUG
        FeedShiftProbe.shared.scrolled(scrollView)
        #endif
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
        if !decelerate { scrollEnded(); releaseHeld() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollEnded(); releaseHeld() }

    /// While the person drags or the list decelerates away from the top, changes wait (FEED-15).
    /// Not during a jump to the top (it keeps no anchor) and not before the first snapshot.
    private func holdsForScroll(_ view: UITableView) -> Bool {
        guard !releasing, view.isTracking || view.isDecelerating, !jumpingToTop,
              dataSource?.snapshot().numberOfSections ?? 0 > 0 else { return false }
        return !syncAtTop()
    }

    /// The pill counts the held rows that are new (never shown, not a fold line) while they wait.
    private func countHeld(_ next: [FeedItem]) {
        let fresh = next.reduce(0) { count, item in
            count + (shownSet.contains(item.id) || everShown.contains(item.id) || FeedStacks.isFold(item.id) ? 0 : 1)
        }
        if fresh != heldCounted {
            control.newAbove += fresh - heldCounted
            heldCounted = fresh
        }
    }

    /// At rest: what waited applies in one pass, with the reader's row kept in place.
    private var releasing = false
    private func releaseHeld() {
        if let partChanged = headerHeld {
            headerHeld = nil
            releasing = true
            measureHeader(partChanged: partChanged)
            releasing = false
        }
        guard heldUntilRest else { return }
        heldUntilRest = false
        trace("released at rest")
        control.newAbove = max(0, control.newAbove - heldCounted)
        heldCounted = 0
        releasing = true
        applyScheduled = true
        applyPending()
        releasing = false
    }

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
            self.scheduleSpare()
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
        let layout = FeedRowLayout.make(key(for: item), styles: styles, scale: scale)
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        if states[id]?.copied != true { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7) }
        mutateState(id, animated: false) { $0.copied = true }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.mutateState(id, animated: false) { $0.copied = false }
        }
    }

    func rowCopyCommand(_ id: String) {
        guard let item = items[id], case .permission(let request) = item.kind else { return }
        UIPasteboard.general.string = request.toolCall.command
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
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

    func rowPeek(_ id: String) -> UIViewController? {
        guard let item = items[id], let list = collectionView else { return nil }
        let chat = context.chat(item)
        let content = FeedPeek.content(opensTerminal: item.opensTerminal, hasLink: item.link != nil, loadedTurns: chat?.turns.count ?? 0)
        let container = list.window?.bounds.size ?? list.bounds.size
        return FeedPeekView.controller(item: item, chat: content == .chat ? chat : nil, container: container)
    }

    func rowPeekCommit(_ id: String) {
        guard let item = items[id] else { return }
        context.openFromPeek(item)
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
