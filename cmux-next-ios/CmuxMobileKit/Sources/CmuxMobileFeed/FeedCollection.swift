#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileMarkdown
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
    @ObservationIgnored fileprivate weak var controller: FeedListController?

    func scrollToTop(animated: Bool = true) { controller?.scrollToTop(animated: animated) }
    func scrollTo(id: String, animated: Bool = true) { controller?.scrollTo(id: id, animated: animated) }
    #if DEBUG
    func demo(_ command: DemoDirector.Command) { controller?.demo(command) }
    #endif
}

/// The Feed's list (verify/feed-perf-20261022.md): a `UICollectionView`
/// whose rows are UIKit views only (`FeedRowCell`), with a diffable data
/// source keyed by event id. Each row's layout (`FeedRowLayout`) is
/// computed off the main thread, kept until its event or row state
/// changes, and gives the flow layout exact heights, so scrolling a row in
/// costs placing reused views and nothing else. The SwiftUI rows it replaced
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

final class FeedCollectionView: UICollectionView {
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
final class FeedListController: NSObject, UICollectionViewDelegate, FeedRowCellDelegate {
    enum Section: Hashable { case header, events }
    static let headerID = "feed.header"

    let context: FeedRowContext
    let swipe: FeedSwipeCoordinator
    let control: FeedListControl
    private var store: FeedStore { context.store }

    private(set) var collectionView: FeedCollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>?
    private let layouts = FeedRowLayoutCache<FeedRowLayout>()
    private let listLayout = FeedListLayout()
    private var states: [String: FeedRowState] = [:]
    private var items: [String: FeedItem] = [:]
    /// The events as the list shows them (the applied snapshot's order).
    private var shownOrder: [String] = []
    private var shownKeys: [String: FeedRowKey] = [:]
    /// `shownOrder` as a set, rebuilt only when the order changes.
    private var shownSet: Set<String> = []
    /// Each shown row's height (its shown layout's), so a commit reads no layout it did not change.
    private var shownHeights: [String: CGFloat] = [:]
    /// The latest events from the store, applied once per run-loop turn.
    private var pending: [FeedItem]?
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
    private var minuteTimer: Timer?
    private var replyChats: [String: AgentChatStore] = [:]
    private var previousRead: [String: Bool] = [:]
    /// Every event id the list has shown this session (the "N new" pill counts others only).
    private var everShown: Set<String> = []
    /// Snapshots applied (tests and the rig read it).
    private(set) var applyCount = 0

    deinit {
        MainActor.assumeIsolated { minuteTimer?.invalidate() }
    }

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
        let view = FeedCollectionView(frame: .zero, collectionViewLayout: listLayout)
        view.backgroundColor = .cmuxMobileBackground
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.contentInsetAdjustmentBehavior = .automatic
        view.delegate = self
        // Cells for rows about to scroll in are made and filled in idle time (a new cell costs ~20 ms).
        view.isPrefetchingEnabled = true
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { @MainActor in
                await self?.store.refresh()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        view.refreshControl = refresh
        view.onWidthChange = { [weak self] width in self?.widthChanged(width) }

        let headerCell = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = UIHostingConfiguration { self.header }.margins(.all, 0)
        }
        let rowCell = UICollectionView.CellRegistration<FeedRowCell, String> { [weak self] cell, _, id in
            guard let self, let layout = self.layout(for: id) else { return }
            cell.delegate = self
            cell.apply(layout, item: self.items[id], settled: self.rowsSettled)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: view) { collectionView, indexPath, id in
            indexPath.section == 0
                ? collectionView.dequeueConfiguredReusableCell(using: headerCell, for: indexPath, item: id)
                : collectionView.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: id)
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
        minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibleCells.forEach { $0.refreshTime() } }
        }
        #if DEBUG
        if FeedStressRig.shared.config.autoscrollPasses != nil { FeedScreenRig.scroller.attach(view) }
        #endif
        return view
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
        pending = next.filter { seen.insert($0.id).inserted }
        guard !applyScheduled else { return }
        applyScheduled = true
        // Every write of this run-loop turn (a burst from the Mac) becomes one snapshot.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.applyPending() }
        }
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
        listLayout.headerHeight = height
        listLayout.invalidateLayout()
    }

    private func reconfigureHeader() {
        guard let dataSource, dataSource.snapshot().indexOfItem(Self.headerID) != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([Self.headerID])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The row's layout key. The read flag and the time are drawn, not laid out, so a read
    /// on the Mac (several a second) redraws the dot without laying the row out again.
    private func key(for item: FeedItem) -> FeedRowKey {
        var laidOut = item
        laidOut.isRead = false
        laidOut.createdAt = .distantPast
        return FeedRowKey(item: laidOut, state: states[item.id] ?? FeedRowState(), width: Int(width.rounded()), textSize: textSize)
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
               shown.state == (states[item.id] ?? FeedRowState()), old == item {
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
        defer { for id in redraw { if let item = items[id] { cell(id)?.redraw(item) } } }
        guard !plan.isEmpty || dataSource.snapshot().numberOfSections == 0 else { return }
        // A jump to the top in flight keeps no anchor: restoring one would set the offset and cut the
        // jump's animation short wherever it was (the pill then left the person mid-list).
        let anchor = control.atTop || jumpingToTop ? nil : visibleAnchor()
        let previousOrder = shownOrder
        let previousSet = shownSet
        shownOrder = next.map(\.id)
        if plan.orderChanged { shownSet = Set(shownOrder) }
        if plan.orderChanged || reconfigureAll {
            shownKeys = Dictionary(keys, uniquingKeysWith: { first, _ in first })
        }
        // Each changed row's height, from the layout of the key it is shown with.
        for (id, key) in keys where !unchanged.contains(id) || shownHeights[id] == nil {
            shownKeys[id] = key
            shownHeights[id] = layouts.cached(key)?.height ?? 1
        }
        var snapshot = dataSource.snapshot()
        if snapshot.numberOfSections == 0 {
            snapshot = NSDiffableDataSourceSnapshot<Section, String>()
            snapshot.appendSections([.header, .events])
            snapshot.appendItems([Self.headerID], toSection: .header)
            snapshot.appendItems(shownOrder, toSection: .events)
        } else if plan.orderChanged {
            // Inserts and removals with the rest in order (a live event, a done swipe): edits, not a new
            // snapshot of every row to diff. Anything else (a re-sort) rebuilds the section.
            if !FeedListController.edit(&snapshot, from: previousOrder, to: shownOrder) {
                snapshot.deleteSections([.events])
                snapshot.appendSections([.events])
                snapshot.appendItems(shownOrder, toSection: .events)
            }
        }
        // Reconfigured rows are shown rows by construction (the plan lists only ids it had shown); a
        // relayout's list may name rows the snapshot just removed.
        let reconfigure = plan.orderChanged ? plan.reconfigure.filter { shownSet.contains($0) && previousSet.contains($0) } : plan.reconfigure
        if !reconfigure.isEmpty { snapshot.reconfigureItems(reconfigure) }
        applyCount += 1
        UIView.performWithoutAnimation {
            listLayout.setHeights(order: shownOrder, heights: shownHeights, changed: plan.orderChanged ? nil : reconfigure)
            dataSource.apply(snapshot, animatingDifferences: false)
            if plan.orderChanged || !plan.reconfigure.isEmpty { listLayout.invalidateLayout() }
            if let anchor { restore(anchor) }
            continueJumpToTop()
        }
        if let anchor {
            // Only events never shown before count as new (an undone Done or a filter switch does not).
            let fresh = FeedListPlan.fresh(plan.inserted, seen: &everShown)
            let above = shownOrder.prefix { $0 != anchor.id }.count { fresh.contains($0) }
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

    // MARK: Warm-up

    /// Row shapes already drawn once (kind, body, quote, replies): the first draw of a font, a
    /// symbol or a code style cost ~20 ms on the frame a row of that shape first scrolled in.
    private var warmed: Set<String> = []
    private var warmQueue: [FeedRowLayout] = []
    private var warmScheduled = false
    private lazy var warmCell = FeedRowCell(frame: CGRect(x: 0, y: 0, width: max(width, 1), height: 100))

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
            guard let key = shownKeys[id], let layout = layouts.cached(key) else { continue }
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
    /// shows (order, row state) while the rows are laid out again: the visible ones here, the rest off
    /// the main thread; then every row is reconfigured at once, and nothing counts as new.
    private func relayoutAll() {
        guard width > 0 else { return }
        let pendingItems = pending ?? shownOrder.compactMap { items[$0] }
        pending = pendingItems
        let keys = pendingItems.map { key(for: $0) }
        let styles = styles, scale = scale
        let visible = Set(collectionView?.indexPathsForVisibleItems.compactMap { dataSource?.itemIdentifier(for: $0) } ?? [])
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

    private func mutateState(_ id: String, animated: Bool = true, _ change: (inout FeedRowState) -> Void) {
        var state = states[id] ?? FeedRowState()
        change(&state)
        states[id] = state
        refreshRows([id], animated: animated)
    }

    /// Lays out `ids` again at once (a row's own state changed) and reconfigures them.
    private func refreshRows(_ ids: [String], animated: Bool) {
        guard let dataSource, let collectionView else { return }
        let present = ids.filter { shownKeys[$0] != nil && items[$0] != nil }
        guard !present.isEmpty else { return }
        let anchor = control.atTop || jumpingToTop ? nil : visibleAnchor(excluding: Set(present))
        for id in present {
            guard let item = items[id] else { continue }
            let key = key(for: item)
            if layouts.cached(key) == nil { layouts.store(FeedRowLayout.make(key, styles: styles, scale: scale), for: key) }
            shownKeys[id] = key
            shownHeights[id] = layouts.cached(key)?.height ?? 1
        }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(present)
        let apply = {
            self.listLayout.setHeights(order: self.shownOrder, heights: self.shownHeights, changed: present)
            dataSource.apply(snapshot, animatingDifferences: false)
            self.listLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if let anchor { self.restore(anchor) }
            self.continueJumpToTop()
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction], animations: apply)
        } else {
            UIView.performWithoutAnimation(apply)
        }
    }

    private func cell(_ id: String) -> FeedRowCell? {
        guard let indexPath = dataSource?.indexPath(for: id) else { return nil }
        return collectionView?.cellForItem(at: indexPath) as? FeedRowCell
    }

    // MARK: Anchoring

    private struct Anchor { var id: String; var delta: CGFloat }

    /// The first event row on screen and where it starts relative to the scroll offset.
    private func visibleAnchor(excluding: Set<String> = []) -> Anchor? {
        guard let collectionView, let dataSource else { return nil }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let rows = collectionView.indexPathsForVisibleItems.filter { $0.section == 1 }.sorted()
        for indexPath in rows {
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath), attributes.frame.maxY > top,
                  let id = dataSource.itemIdentifier(for: indexPath), !excluding.contains(id) else { continue }
            return Anchor(id: id, delta: attributes.frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    private func restore(_ anchor: Anchor) {
        guard let collectionView, let indexPath = dataSource?.indexPath(for: anchor.id) else { return }
        collectionView.layoutIfNeeded()
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let y = min(max(attributes.frame.minY - anchor.delta, minY), maxY)
        if abs(y - collectionView.contentOffset.y) > 0.25 { collectionView.contentOffset.y = y }
    }

    // MARK: Commands

    /// A jump to the top (the "N new" pill) is under way until it lands or the person drags.
    private var jumpingToTop = false

    func scrollToTop(animated: Bool) {
        guard let collectionView else { return }
        let top = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
        jumpingToTop = animated && abs(collectionView.contentOffset.y - top.y) > 0.25
        collectionView.setContentOffset(top, animated: jumpingToTop)
        if !jumpingToTop, collectionView.contentOffset != top { collectionView.contentOffset = top }
        control.newAbove = 0
    }

    /// A snapshot applied during a jump to the top can move or stop the animated offset: aim at
    /// the top again so the jump still lands there.
    private func continueJumpToTop() {
        guard jumpingToTop, let collectionView else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard jumpingToTop else { return }
        jumpingToTop = false
        // Land exactly at the top, whatever changed while the list moved.
        let top = -scrollView.adjustedContentInset.top
        if abs(scrollView.contentOffset.y - top) > 0.25 { scrollView.contentOffset.y = top }
    }

    func scrollTo(id: String, animated: Bool) {
        guard let collectionView, let indexPath = dataSource?.indexPath(for: id),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        // The row's top under the bars (scrollToItem(.top) ignores the safe area's top inset).
        let maxY = max(-collectionView.adjustedContentInset.top,
                       collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let y = min(attributes.frame.minY - collectionView.adjustedContentInset.top, maxY)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    // MARK: Cells

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // A cell filled ahead (prefetch) missed redraws (a read flag, the minute) while off screen.
        if let cell = cell as? FeedRowCell, let id = cell.layout?.key.item.id, let item = items[id] {
            if cell.shownRead != item.isRead { cell.redraw(item) }
            if CACurrentMediaTime() - cell.timeDrawnAt > 30 { cell.refreshTime() }
        }
        #if DEBUG
        if FeedCellTiming.enabled { FeedCellTiming.logger.notice("FEEDCELL willDisplay \(indexPath.item, privacy: .public) y=\(Int(collectionView.contentOffset.y), privacy: .public)") }
        #endif
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? FeedRowCell, let id = cell.layout?.key.item.id else { return }
        // A row scrolled away closes, so no open row outlives its registration (the drawer would open over it).
        if cell.isOpen { cell.close() }
        RowSwipeActions.shared.setOpen(registrationKey(id), close: nil)
        if swipe.openID == id { swipe.openID = nil }
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top < 60
        if top != control.atTop { control.atTop = top }
        if top {
            if control.newAbove != 0 { control.newAbove = 0 }
            store.clearUnseen()
        }
        markMoving()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The person took over: a jump to the top in flight ends where they caught it.
        jumpingToTop = false
        if swipe.openID != nil { swipe.openID = nil }
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

    private func registrationKey(_ id: String) -> String { "feed.\(ObjectIdentifier(swipe)).\(id)" }

    private func observeSwipe() {
        withObservationTracking {
            _ = swipe.openID
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
        for cell in visibleCells where cell.isOpen && cell.layout?.key.item.id != swipe.openID { cell.close() }
        guard swipe.demoSerial != lastDemoSerial else { return }
        lastDemoSerial = swipe.demoSerial
        if let id = swipe.demoReveal { cell(id)?.reveal() }
        if let (id, action) = swipe.demoPerform { cell(id)?.perform(actionID: action) }
    }

    func rowSwipeBegan(_ id: String) {
        swipe.openID = id
    }

    func rowSwipeOpenChanged(_ id: String, open: Bool) {
        RowSwipeActions.shared.setOpen(registrationKey(id), close: open ? { [weak self] in self?.cell(id)?.close() } : nil)
        if !open, swipe.openID == id { swipe.openID = nil }
    }

    func rowSwipeActions(_ id: String) -> [FeedSwipeAction] {
        guard let item = items[id] else { return [] }
        let context = context
        return item.swipeActions(store: store, open: { context.open(item) })
    }

    // MARK: Row actions

    func rowOpen(_ id: String) {
        guard let item = items[id] else { return }
        context.open(item)
    }

    func rowToggleExpanded(_ id: String) {
        mutateState(id) { $0.expanded.toggle() }
    }

    func rowToggleQuote(_ id: String) {
        mutateState(id) { $0.quoteExpanded.toggle() }
    }

    func rowToggleReply(_ id: String) {
        let opening = !(states[id]?.replying ?? false)
        mutateState(id) { $0.replying = opening }
        guard opening, let indexPath = dataSource?.indexPath(for: id) else { return }
        collectionView?.scrollToItem(at: indexPath, at: .bottom, animated: true)
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
        mutateState(id) { $0.codeExpanded = true }
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

#endif
