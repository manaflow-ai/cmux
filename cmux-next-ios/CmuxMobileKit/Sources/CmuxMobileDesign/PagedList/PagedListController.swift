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

/// How a list's rows answer its bottom edge moving: the keyboard, a composer that grows, a bar that
/// comes or goes (verify/paged-list.md, "Bottom edge").
public enum PagedListBottomPinning: Sendable, Hashable {
    /// The rows ride the bottom edge: a reader at the newest end of an `.up` list stays on it, any
    /// other reader keeps their distance to the edge, so what they read goes up with the keyboard
    /// (Messages, Telegram). The `.up` default.
    case ridesBottomEdge
    /// The rows stay where they are on screen; the edge covers or uncovers the bottom. The `.down`
    /// default.
    case keepsRows
}

/// What a screen's newest-rows indicator draws from (``PagedList/pagedNewestIndicator(_:)``): each
/// screen draws its own (a pill, a badge, nothing).
public struct PagedListNewest {
    /// Rows that arrived at the newest end since the reader left it.
    public var unseen: Int
    /// The reader is away from the newest end (more than half a screen; back within a quarter).
    public var isAway: Bool
    /// Takes the reader to the newest end (on the list's spring; at once with Reduce Motion).
    public var jump: @MainActor () -> Void

    public init(unseen: Int, isAway: Bool, jump: @escaping @MainActor () -> Void) {
        self.unseen = unseen
        self.isAway = isAway
        self.jump = jump
    }
}

/// The indicator's live state (the list writes it, the indicator's view observes it).
@MainActor
@Observable
final class PagedListNewestState {
    /// Arrivals the list saw while the reader was away.
    var arrived = 0
    /// Arrivals a windowed model kept out of the list (they never reached it).
    var beyondWindow = 0
    var isAway = false
    @ObservationIgnored var jump: @MainActor () -> Void = {}
    var value: PagedListNewest { PagedListNewest(unseen: arrived + beyondWindow, isAway: isAway, jump: jump) }
}

/// What a test or a lab learns from a ``PagedList`` as it works (nil in the app).
@MainActor
public final class PagedListProbe {
    /// A page or a live item landed: how far the row the reader was looking at moved on screen (pt),
    /// measured after the layout pass that placed it and the self-sizing that followed.
    public var pageLanded: ((_ shift: CGFloat, _ rows: Int) -> Void)?
    /// The reader started (true) or stopped (false) moving the list.
    public var scrolling: ((Bool) -> Void)?
    /// The row being read: the first row under the list's top edge, after the last layout pass.
    public internal(set) var readingID: AnyHashable?
    /// After every committed frame, while set: how far the row being read moved on screen beyond what
    /// the scroll explains (the person's drag or fling, the status bar's scroll to top, or the
    /// list's own deliberate moves: following the newest row, riding the bottom edge). 0 when
    /// nothing shifted; the stress bench fails on anything over half a point.
    public var frameShift: ((CGFloat) -> Void)?
    /// The same measure taken at each layout pass instead (DEBUG, beside `frameShift` so a run shows
    /// what one counts and the other doesn't): a pass can see the list mid-placement, which never
    /// draws. `midPlacement` when the list's own window frame at this pass or the last one differs
    /// from where the last committed frame drew it; `detail` for a shift over half a point.
    public var passFrameShift: ((_ shift: CGFloat, _ midPlacement: Bool, _ detail: String?) -> Void)?
    /// How long the committed-frame measure took for one drawn frame, in milliseconds (DEBUG): the
    /// stress bench reports it beside its hitches, since a run without the probe has no such cost.
    public var samplerCost: ((_ ms: Double) -> Void)?
    /// After every committed frame, while set (DEBUG): how far the rows drew on screen beyond what the
    /// scroll explains, read from their cells' presentation layers (what Core Animation shows, with
    /// animations), not from the layout. The row being read when it survives, else the first row on
    /// screen in both frames. A move of the offset and the layout together (a windowed swap, a
    /// correction) draws nothing and reads 0; a move that draws counts, whatever the layout says.
    public var drawnShift: ((_ shift: CGFloat, _ detail: String?) -> Void)?
    /// After every committed frame, while set (DEBUG): the largest drawn move beyond the scroll of
    /// the rows around the eye line (``PagedListFollow/neighbourShift(previous:current:reading:explained:around:)``),
    /// a check that does not share the rule by which the anchor or the measures pick their row.
    public var neighbourShift: ((_ shift: CGFloat, _ detail: String?) -> Void)?
    /// A frame that shifted more than half a point, with what the list was doing (the lab keeps the
    /// worst one, so a failing stress case names its cause).
    public var shiftDetail: ((_ shift: CGFloat, _ detail: String) -> Void)?
    /// The list slid to its newest end on its spring (a row arrived, or the indicator's jump), in
    /// this many display frames: more than one is an animation, not a jump.
    public var slid: ((_ frames: Int) -> Void)?
    /// Rows arrived at the newest end under a resting finger and wait for it to lift.
    public var held: ((_ rows: Int) -> Void)?

    public init() {}
}

/// The list's cell ids: one per row, and the paging edge.
enum PagedListCellID<ID: Hashable & Sendable>: Hashable, Sendable {
    case row(ID)
    /// The older edge.
    case edge
    /// The newer edge of a windowed model (rows held on disk while the reader is deep).
    case newerEdge
}

/// Which paging edge a view is for.
enum PagedListEnd: Sendable {
    case older, newer
}

/// A list layout (UIKit's, for its swipe actions and native scrolling) that keeps what the reader
/// sees in place when a row above them changes height: a row that came in with an estimated height
/// and measured on its way into view, a reconfigure, a text-size change. UIKit's own layout moves
/// the rows under the reader by the difference (the "jump while scrolling up" every chat list has).
final class PagedListLayout: UICollectionViewCompositionalLayout {
    /// Corrections made (tests and the lab).
    private(set) var corrections = 0
    /// Each correction as it is made (the frame-shift measure tells it from a scroll).
    var corrected: ((CGFloat, Int?) -> Void)?

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        guard let collectionView else { return context }
        guard context.contentOffsetAdjustment == .zero else {
            // UIKit's own adjustment for this row: a correction for the measure, not a scroll.
            corrected?(context.contentOffsetAdjustment.y, preferred.indexPath.item)
            return context
        }
        let delta = preferred.frame.height - original.frame.height
        guard abs(delta) > 0.25 else { return context }
        // The row starts above the reader's top edge: everything the reader sees is below it and would
        // move by `delta`. Move the viewport with it.
        let readerTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        guard original.frame.minY < readerTop - 0.5 else { return context }
        context.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
        corrections += 1
        corrected?(delta, preferred.indexPath.item)
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
    /// Every size the cell gives the layout, with the attributes the layout had for it: UIKit may
    /// move the offset for it outside a layout pass (a cell it prepares ahead of the scroll).
    var sized: ((UICollectionViewLayoutAttributes, CGFloat) -> Void)?

    override func prepareForReuse() {
        super.prepareForReuse()
        knownHeight = nil
        measured = nil
        sized = nil
    }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let width = attributes.size.width
        if let height = knownHeight?(width) {
            let fitted = attributes.copy() as? UICollectionViewLayoutAttributes ?? attributes
            fitted.size = CGSize(width: width, height: height)
            sized?(attributes, height)
            return fitted
        }
        let fitted = super.preferredLayoutAttributesFitting(attributes)
        measured?(width, fitted.size.height)
        sized?(attributes, fitted.size.height)
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

    /// How many screens lie between the viewport and the newest end (the top of a `.down` list,
    /// the bottom of an `.up` one).
    public func pagedScreensToNewest(_ direction: PagedListDirection) -> CGFloat {
        pagedScreensToEdge(direction == .down ? .up : .down)
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
    var willLayout: (() -> Void)?
    var didLayout: (() -> Void)?
    /// While a set of the offset runs, what it asked for (each outermost set numbered): UIKit may
    /// move the offset further inside it (rows above it sized as they came into view, with the
    /// content moved by as much), which is its correction, not the finger's or the fling's move.
    private(set) var offsetRequest: (serial: Int, from: CGFloat, y: CGFloat)?
    private var requests = 0

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            let outer = offsetRequest == nil
            if outer {
                requests += 1
                offsetRequest = (requests, super.contentOffset.y, newValue.y)
            }
            super.contentOffset = newValue
            if outer { offsetRequest = nil }
        }
    }
    /// VoiceOver's three-finger scroll down at the top refreshes, as it does with `UIRefreshControl`.
    var accessibilityRefresh: (() -> Bool)?

    /// A VoiceOver page scroll moved the list (no finger, no fling).
    var accessibilityScrolled: (() -> Void)?

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if direction == .up, accessibilityRefresh?() == true { return true }
        let scrolled = super.accessibilityScroll(direction)
        if scrolled { accessibilityScrolled?() }
        return scrolled
    }

    /// Inside a layout pass: an offset move now is the layout's or UIKit's own (a self-sized row's
    /// correction, a batch update), never the person's scroll, which moves it between passes.
    private(set) var laying = 0
    /// Inside the layer's layout, which runs `layoutSubviews` and then UIKit's own work after it.
    private(set) var layingLayer = 0

    override func layoutSubviews() {
        laying += 1
        defer { laying -= 1 }
        willLayout?()
        super.layoutSubviews()
        didLayout?()
    }

    override func layoutSublayers(of layer: CALayer) {
        layingLayer += 1
        defer { layingLayer -= 1 }
        super.layoutSublayers(of: layer)
    }
}

/// The UIKit side of ``PagedList`` (verify/paged-list.md): a diffable list whose rows are SwiftUI,
/// which reads the next page ahead of the reader, never moves what they read when a page or a live row
/// lands, follows the newest row on a spring while the reader is there, and answers its bottom edge
/// moving the way ``PagedListBottomPinning`` says.
@MainActor
final class PagedListController<Item: Identifiable & Equatable, Row: View>: NSObject, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching where Item.ID: Sendable {
    typealias CellID = PagedListCellID<Item.ID>

    let direction: PagedListDirection
    let collectionView: PagedListCollectionView
    private let layout: PagedListLayout
    private var dataSource: UICollectionViewDiffableDataSource<Int, CellID>!

    var row: (Item) -> Row
    var edgeView: (PagedListEdge, PagedListEnd) -> AnyView
    var swipeActions: ((Item) -> [PagedListAction])?
    var loadMore: () -> Void = {}
    /// Reads the newer rows a windowed model holds on disk.
    var loadNewer: () -> Void = {}
    /// The row being read, as it changes (a windowed model keeps its window around it).
    var onReading: ((Item.ID) -> Void)?
    /// A windowed model's own jump to its newest rows (they may be on disk).
    var showNewest: (() -> Void)?
    var probe: PagedListProbe? {
        didSet {
            guard (probe == nil) != (commitWatch == nil) else { return }
            commitWatch = probe == nil ? nil : PagedListCommitWatch { [weak self] in self?.timedSampleCommitted() }
        }
    }
    var pinning: PagedListBottomPinning
    /// New rows at the newest end slide in on a spring while the reader is there.
    var animatesNewest = true
    var prefetch: (([Item]) -> Void)?
    var cancelPrefetch: (([Item]) -> Void)?
    /// Screens ahead of the edge at which the next page is asked for.
    var readAheadScreens: CGFloat = 2
    /// Rows keep their measured height while their value is the same; off for rows whose height
    /// depends on state outside the item.
    var cachesHeights = true
    /// The newest-rows indicator's state.
    let newest = PagedListNewestState()

    private var items: [Item.ID: Item] = [:]
    private var order: [Item.ID] = []
    private var edge: PagedListEdge = .end
    private var newerEdge: PagedListEdge = .end
    private var showsEdge = false
    private var showsNewerEdge = false
    private var heights: [Item.ID: (width: CGFloat, height: CGFloat)] = [:]
    /// The reader is at the newest end: the top of a `.down` list, the bottom of an `.up` one.
    /// An `.up` list that follows stays at the bottom through every layout pass.
    private(set) var followsNewest = true
    private var loaded = false
    private var lastBoundsWidth: CGFloat = 0
    /// The viewport's bottom edge in window coordinates after the last layout pass.
    private var lastBottomEdge: CGFloat?
    private var bottomGap: CGFloat = 0
    private var readAheadQueued = false
    /// Where the reader is, from the end of the last layout pass: what the next pass puts back.
    private var kept: Anchor?
    /// A layout pass is putting the reader back (setting the offset lays out again).
    private var keeping = false
    /// A layout pass runs (an inset it changes calls back into it).
    private var laying = false
    /// A snapshot is being applied and the reader put back: its layout passes are not frames anyone
    /// sees (the frame-shift measure samples once, after it).
    private var updating = false
    /// Rows are landing at the newest end of an `.up` list (the spring takes it there, not a jump).
    private var arriving = false
    /// The status bar's scroll to top is running: it moves the list on purpose.
    private var scrollingToTop = false
    private var lastReported: Item.ID?
    private(set) var applies = 0
    private var refreshAction: (() async -> Void)?
    /// Pull to refresh under the search drawer (`ListPullToRefresh` says why not `UIRefreshControl`).
    private var pullToRefresh: ListPullToRefresh?
    private let spring = PagedListScrollSpring()

    // The frame-shift measure (only while `probe.frameShift` is set).
    private struct ShiftSample {
        var id: CellID
        var next: CellID?
        var gap: Int?
        /// The row's top, or its bottom for an `.up` list at its newest row.
        var bottom: Bool
        var windowY: CGFloat
        var width: CGFloat
        var offsetY: CGFloat
    }
    private var shiftSample: ShiftSample?
    /// The committed-frame measure's last sample, where the last committed frame drew the list, and
    /// where the last layout pass found it (the pass measure's mid-placement mark).
    private var committedSample: ShiftSample?
    /// The rows on screen when the committed-frame measure last sampled (``PagedListFollow``).
    private var committedRows: [PagedListFollow.Row<CellID>] = []
    private var committedFrame: CGRect?
    private var passFrame: CGRect?
    private var commitWatch: PagedListCommitWatch?
    /// The committed-frame measure's detail (DEBUG, while `shiftDetail` is set): the offset moves
    /// noted since the last committed frame, and the last frames' drawn rows: per frame, the reader
    /// row's top and the next row's top in the window, the offset, and what the scroll and the
    /// list's own moves (the spring's slide) explained. A steady slide moves both rows by what it
    /// explains; a jump moves them by more, for a frame.
    private var commitTrail: [PagedListTrailNote] = []
    private struct DrawnFrame {
        var number: Int
        var read: CGFloat
        var next: CGFloat
        var offset: CGFloat
        var explained: CGFloat
        var spring: Bool
        var trail: [PagedListTrailNote]
    }
    /// Kept as numbers; formatted only when a shift is reported (each frame's string cost a busy
    /// main thread its frames: up-fast-busy, steps 6d8bcee4 and f902d4d6).
    private var drawnFrames: [DrawnFrame] = []
    private var committedFrames = 0
    /// The drawn measure's last frame: each row on screen's drawn top in the window, in screen order,
    /// and the row being read.
    private var drawnRows: [(id: CellID, y: CGFloat)] = []
    private var drawnHeights: [CellID: CGFloat] = [:]
    private var drawnReading: CellID?
    /// What the scroll explains since the last sample, and the corrections UIKit still owes.
    private var ledger = PagedListShiftLedger()
    /// Counts every offset move the scroll explains (the finger, a fling, the list's own slide): a
    /// landing measured after one is judged per frame instead.
    private var explainedMoves = 0
    private var lastOffsetY: CGFloat = 0
    /// Depth of the list's own deliberate moves (explained) and corrections (not explained).
    private var ownMoves = 0
    private var corrections = 0
    /// The offset moves since the last sample and how the measure read each (the probe's detail).
    private var trail: [PagedListTrailNote] = []
    /// The previous sample's interval as the detail shows it (its source, trail and the correction
    /// UIKit still owed when it was taken): a shift can start in one interval and land in the next.
    private var previousInterval = PagedListPreviousInterval()
    /// Depth of the controller's own reads of the layout outside a pass (an anchor, the measure):
    /// UIKit may apply layout work it deferred inside one.
    private var querying = 0
    private var scrollDepth = 0
    /// Rows that arrived at the newest end under a resting finger: they slide in when it lifts, or
    /// count on the indicator when a drag starts instead.
    private var heldArrivals = 0
    /// The last offset set whose own part the measure counted as the scroll.
    private var countedRequest = 0
    /// How far rows that arrived at the newest end while the person scrolled there (held out of view)
    /// moved that end: the list still counts as at its newest end within this, and slides on to
    /// them when the scroll ends.
    private var heldHeight: CGFloat = 0
    /// While the reader scrolls: the row under the reader's top edge and its top on screen as drawn
    /// when a layout pass starts.
    private var passHold: (id: CellID, top: CGFloat)?

    init(direction: PagedListDirection, row: @escaping (Item) -> Row, edgeView: @escaping (PagedListEdge, PagedListEnd) -> AnyView) {
        self.direction = direction
        self.row = row
        self.edgeView = edgeView
        pinning = direction == .up ? .ridesBottomEdge : .keepsRows
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
        layout.corrected = { [weak self] delta, item in
            guard let self else { return }
            self.ledger.corrected(delta, item: item)
            self.note(self.collectionView.laying > 0 ? "AL" : self.collectionView.layingLayer > 0 ? "AS" : "A", delta)
        }
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.allowsSelection = false
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        // A tap on the status bar goes to the newest end, which is the bottom of an `.up` list.
        collectionView.scrollsToTop = direction == .down

        let rowCell = UICollectionView.CellRegistration<PagedListCell, Item.ID> { [weak self] cell, _, id in
            self?.configure(cell, id)
        }
        let edgeCell = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, which in
            guard let self else { return }
            let end: PagedListEnd = which == 0 ? .older : .newer
            let view = self.edgeView(end == .older ? self.edge : self.newerEdge, end)
            cell.contentConfiguration = UIHostingConfiguration { view }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id -> UICollectionViewCell? in
            switch id {
            case .row(let rowID): return view.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: rowID)
            case .edge: return view.dequeueConfiguredReusableCell(using: edgeCell, for: indexPath, item: 0)
            case .newerEdge: return view.dequeueConfiguredReusableCell(using: edgeCell, for: indexPath, item: 1)
            }
        }
        spring.target = { [weak self] in self?.newestOffset ?? 0 }
        spring.current = { [weak self] in self?.collectionView.contentOffset.y ?? 0 }
        spring.holds = { [weak self] in self?.collectionView.isTracking ?? false }
        spring.apply = { [weak self] y in self?.moveOffset(to: y) }
        spring.finished = { [weak self] frames in
            guard let self else { return }
            // The slide ends at the newest end: the list follows it from here.
            self.followsNewest = true
            self.heldArrivals = 0
            self.heldHeight = 0
            self.newest.arrived = 0
            self.probe?.slid?(frames)
        }
        newest.jump = { [weak self] in self?.jumpToNewest() }
        collectionView.accessibilityScrolled = { [weak self] in self?.scrollEndedByCode() }
        collectionView.willLayout = { [weak self] in self?.willLayout() }
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
        cell.sized = { [weak self] attributes, height in self?.rowSized(attributes, height) }
        guard cachesHeights else { return }
        cell.knownHeight = { [weak self] width in
            guard let known = self?.heights[id], known.width == width else { return nil }
            return known.height
        }
        cell.measured = { [weak self] width, height in self?.heights[id] = (width, height) }
    }

    /// A row's cell gave the layout its size: one that differs from what the layout had, for a row
    /// starting above the reader's top edge, is corrected by the offset (by UIKit, or by
    /// ``PagedListLayout``) to keep what the reader sees in place.
    private func rowSized(_ attributes: UICollectionViewLayoutAttributes, _ height: CGFloat) {
        let delta = height - attributes.size.height
        guard abs(delta) > 0.25 else { return }
        let above = attributes.frame.minY < readerTop - 0.5
        ledger.sized(item: attributes.indexPath.item, by: delta, aboveReader: above)
        note(above ? "m" : "m_", delta)
    }

    /// The newest row's id (the top of a `.down` list, the bottom of an `.up` one).
    private func newestID(in ids: [Item.ID]) -> Item.ID? { direction == .down ? ids.first : ids.last }

    /// Shows `given` (top to bottom) and both edges' states. Rows whose value changed are drawn
    /// again in place; rows that came or went above the reader leave what they read where it was;
    /// rows that arrive at the newest end while the reader is there slide in.
    func update(items given: [Item], edge newEdge: PagedListEdge, newerEdge newNewerEdge: PagedListEdge = .end) {
        // The diffable data source raises on a repeated id: a source that sends one twice shows it
        // once (the first).
        var seen = Set<Item.ID>()
        let newItems = given.filter { seen.insert($0.id).inserted }
        let newOrder = newItems.map(\.id)
        querying += 1
        var stillQuerying = true
        defer { if stillQuerying { querying -= 1 } }
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
        let newerEdgeChanged = newNewerEdge != newerEdge
        let newShowsEdge = newEdge != .end || edgeHasEndView
        let newShowsNewerEdge = newNewerEdge != .end
        // Rows a windowed model brings back from disk at its newer edge are not new: only rows that
        // land while the list holds its newest rows arrive.
        let heldNewest = newerEdge == .end
        edge = newEdge
        newerEdge = newNewerEdge
        guard newOrder != order || newShowsEdge != showsEdge || newShowsNewerEdge != showsNewerEdge || !changed.isEmpty
            || edgeChanged || newerEdgeChanged || !loaded else { return }
        let rowsChanged = newOrder != order || newShowsEdge != showsEdge || newShowsNewerEdge != showsNewerEdge
        let distanceBefore = distanceToNewest

        // Rows that arrived at the newest end: the rows now on the newest side of the old newest row.
        let oldNewest = newestID(in: order)
        var arrivals = 0
        if loaded, heldNewest, let oldNewest, oldNewest != newestID(in: newOrder), let at = newOrder.firstIndex(of: oldNewest) {
            arrivals = direction == .down ? at : newOrder.count - 1 - at
        }
        let animates = animatesNewest && !UIAccessibility.isReduceMotionEnabled
        // A finger on the list, or a fling still moving it, holds the rows under it: rows that arrive
        // then land out of view, and slide in when the finger lifts or the fling ends at the newest
        // end (the spring never fights the scroll).
        let follows = followsNewest && !collectionView.isTracking && !collectionView.isDecelerating
        // A `.down` list following its newest row keeps the rows in place too, then slides to the
        // new top; an `.up` one slides to the new bottom (the rows below the reader are new).
        let slidesDown = direction == .down && follows && arrivals > 0 && animates
        // An `.up` list at its newest row stays on it after each layout pass, except while rows arrive
        // and its slide runs: then it keeps its rows too, so a page or rows landing or leaving above
        // (a full window dropping its oldest row) don't move them (rows that arrive below move
        // nothing above).
        // A `.down` list mid-slide keeps its rows the same way (the new rows above it can change).
        let holdsForSlide = follows && (spring.isRunning || (direction == .up && arrivals > 0))
        // An `.up` list at its newest end keeps its lowest row's bottom where it is, as Messages does:
        // a change above pushes the older rows up, never the newest down.
        // Rows that changed height (an edit) count too: mid-scroll or mid-slide, no layout pass after
        // the update keeps the reader (`keepReader` waits for the scroll to end), and UIKit's own
        // self-sizing move keeps a different edge than the reader's.
        let anchor = (rowsChanged || !changed.isEmpty) && loaded && (!follows || slidesDown || holdsForSlide)
            ? captureAnchor(fromBottom: direction == .up && followsNewest) : nil
        items = next
        order = newOrder
        showsEdge = newShowsEdge
        showsNewerEdge = newShowsNewerEdge
        if rowsChanged { heights = heights.filter { next[$0.key] != nil } }

        var snapshot = NSDiffableDataSourceSnapshot<Int, CellID>()
        snapshot.appendSections([0])
        var ids = newOrder.map { CellID.row($0) }
        let olderAtTop = direction == .up
        if newShowsEdge {
            if olderAtTop { ids.insert(.edge, at: 0) } else { ids.append(.edge) }
        }
        if newShowsNewerEdge {
            if olderAtTop { ids.append(.newerEdge) } else { ids.insert(.newerEdge, at: 0) }
        }
        snapshot.appendItems(ids)
        let present = Set(dataSource.snapshot().itemIdentifiers)
        var reconfigure = changed.filter { present.contains($0) }
        if edgeChanged, present.contains(.edge), newShowsEdge { reconfigure.append(.edge) }
        if newerEdgeChanged, present.contains(.newerEdge), newShowsNewerEdge { reconfigure.append(.newerEdge) }
        snapshot.reconfigureItems(reconfigure)
        applies += 1
        // The new rows' move to the newest end is the slide (or, without motion, the jump) below,
        // the list's own: the layout pass doesn't pin them first.
        arriving = direction == .up && follows && arrivals > 0
        note(anchor == nil ? "@n" : "@a\(changed.count)", 0)
        stillQuerying = false
        querying -= 1
        updating = true
        // No diff animation: a page lands out of view, or under a reader who stays put; rows that
        // arrive at the newest end slide in on the list's spring below.
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()
        arriving = false
        // Rows that came or went: put the reader back now, also mid-fling (an `.up` list's older page
        // lands above a reader who is still scrolling into it).
        let used = anchor.flatMap { restore($0) }
        keepReader()
        if !loaded, direction == .up { scrollToNewest() }
        updating = false
        if arrivals > 0, followsNewest, !follows {
            heldHeight += max(0, distanceToNewest - distanceBefore)
        }
        loaded = true
        // The state this update leaves is what the next frame draws: measure it once, here.
        sampleShift(from: "update")
        if arrivals > 0 {
            if follows {
                if animates {
                    spring.run(from: collectionView.contentOffset.y)
                } else {
                    scrollToNewest()
                }
            } else if followsNewest, collectionView.isTracking, !collectionView.isDragging {
                // A finger rests on the list at its newest end: the rows stay under it (the anchor
                // held them) and the new ones slide in when it lifts (the spring waits for it). A
                // drag that starts instead counts them on the indicator.
                heldArrivals += arrivals
                probe?.held?(arrivals)
                spring.run(from: collectionView.contentOffset.y, jump: !animates)
            } else {
                newest.arrived += arrivals
            }
        }
        if rowsChanged { reportShift(used) }
        queueReadAhead()
    }

    /// Whether `.end` shows a row (an end label).
    var edgeHasEndView = false

    // MARK: Keeping the reader in place

    /// The rows being read, in list order, each with its top in window coordinates (a banner or a
    /// search drawer that moves the whole list counts as moving them).
    private struct Anchor {
        struct Row {
            var id: CellID
            var index: Int
            var windowY: CGFloat
            /// `windowY` is the row's bottom, not its top.
            var bottom = false
        }
        var rows: [Row]
        /// The rows' bottoms, lowest first (an `.up` list at its newest end), not their tops.
        var fromBottom = false
        /// The first row is cut by the reader's top edge. It counts as above the reader, as it does
        /// for the layout's own correction (``PagedListLayout``): ``restore(_:shiftedBy:deliberate:)``
        /// keeps the rows below it still, so a change of its height does not move what is read.
        /// Keeping its top still instead moved every row under it by the change, the list at rest
        /// (#47121 step d20b5519, video frames 351-352: the straddling row grew a line and the rows
        /// read moved down 20 pt).
        var straddles = false
        var id: CellID? { rows.first?.id }
    }

    private var readerTop: CGFloat { collectionView.contentOffset.y + collectionView.adjustedContentInset.top }

    /// The rows on screen whose bottom is below the reader's top edge (the first is the one being read),
    /// or, `fromBottom`, those whose top is above the bottom edge, lowest first, by their bottoms.
    private func captureAnchor(fromBottom: Bool = false) -> Anchor? {
        querying += 1
        defer { querying -= 1 }
        if fromBottom {
            let bottom = bottomEdgeY
            var rows: [Anchor.Row] = []
            for indexPath in collectionView.indexPathsForVisibleItems.sorted().reversed() {
                guard let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                      attributes.frame.minY < bottom - 0.5,
                      let id = dataSource.itemIdentifier(for: indexPath), case .row = id else { continue }
                rows.append(Anchor.Row(id: id, index: indexPath.item, windowY: windowY(attributes, bottom: true), bottom: true))
            }
            return rows.isEmpty ? nil : Anchor(rows: rows, fromBottom: true)
        }
        let top = readerTop
        var rows: [Anchor.Row] = []
        var straddles = false
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                  attributes.frame.maxY > top + 0.5,
                  let id = dataSource.itemIdentifier(for: indexPath), case .row = id else { continue }
            if rows.isEmpty { straddles = attributes.frame.minY < top - 0.5 }
            rows.append(Anchor.Row(id: id, index: indexPath.item, windowY: windowY(attributes)))
        }
        return rows.isEmpty ? nil : Anchor(rows: rows, straddles: straddles && rows.count > 1)
    }

    private func windowY(_ attributes: UICollectionViewLayoutAttributes, bottom: Bool = false) -> CGFloat {
        collectionView.convert(CGPoint(x: 0, y: bottom ? attributes.frame.maxY : attributes.frame.minY), to: nil).y
    }

    private func windowY(of id: CellID, bottom: Bool = false) -> CGFloat? {
        guard let indexPath = dataSource.indexPath(for: id),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
        return windowY(attributes, bottom: bottom)
    }

    /// The list's bottom edge in content coordinates (above the keyboard, an accessory, a bar).
    private var bottomEdgeY: CGFloat {
        collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
    }

    /// Puts the reader back: the first row of `anchor` that is still in the list and kept its place
    /// among the others goes back to where it was on screen, moved by `shift` (the bottom edge's
    /// move, when the rows ride it). A row that left (removed, filtered out) or moved (to the newest
    /// end, re-sorted) is skipped: following it would carry the reader away. Returns the row used.
    @discardableResult
    private func restore(_ anchor: Anchor, shiftedBy shift: CGFloat = 0, deliberate: Bool = false) -> Anchor.Row? {
        let survivors = anchor.rows.dropFirst(anchor.straddles ? 1 : 0).compactMap { row in dataSource.indexPath(for: row.id).map { (row, $0.item) } }
        guard !survivors.isEmpty else { return nil }
        guard let pick = PagedListAnchorPick.pick(survivors.map { PagedListAnchorPick.Row(oldIndex: $0.0.index, newIndex: $0.1) }).map({ survivors[$0].0 }),
              let now = windowY(of: pick.id, bottom: anchor.fromBottom) else { return nil }
        let delta = now - (pick.windowY + shift)
        note(pick.id == anchor.rows.first?.id ? "r" : "r'", delta)
        guard abs(delta) > 0.25 else { return pick }
        if deliberate { moveOffset(to: collectionView.contentOffset.y + delta) } else { correctOffset(by: delta) }
        return pick
    }

    /// After every layout pass: whatever moved the rows (a page or a live row landing, a row above
    /// that grew, a removal, a banner or drawer above the list, the keyboard, a rotation, a text size
    /// change), the row being read goes back to where it was, before the frame is drawn. Not while
    /// the reader scrolls, not at the newest end (the list follows it), and not while the status
    /// bar's scroll to top runs. Chrome calls this scroll anchoring.
    private func keepReader() {
        guard !keeping else { return }
        keeping = true
        defer { keeping = false }
        // While the reader scrolls the place isn't kept between passes (the scroll moves it; each
        // pass keeps it within itself, `holdAcrossPass`); it is taken again when the scroll ends.
        let reading = collectionView.isTracking || collectionView.isDecelerating || scrollingToTop
        guard loaded, !reading, !followsNewest, !spring.isRunning, collectionView.window != nil else {
            kept = nil
            return
        }
        if let kept { restore(kept) }
        takePlace()
    }

    /// Remembers where the reader is now.
    private func takePlace() {
        kept = followsNewest ? nil : captureAnchor()
        if case .row(let id)? = kept?.id {
            probe?.readingID = AnyHashable(id)
            report(id)
        }
    }

    private func report(_ id: Item.ID) {
        guard let onReading, id != lastReported else { return }
        lastReported = id
        onReading(id)
    }

    /// Reports how far the anchored row moved, after the run loop turn in which its self-sizing settled.
    private func reportShift(_ row: Anchor.Row?) {
        guard let probe else { return }
        let rows = order.count
        guard let row else {
            probe.pageLanded?(0, rows)
            return
        }
        let movesAtLanding = explainedMoves
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            // While the reader scrolls or the list slides, that moves the row between the landing and
            // this turn (also a fling that ended in between, or a slide that ran one frame): the
            // per-frame measure (`frameShift`) judges those landings, not this one.
            let scrolling = self.collectionView.isTracking || self.collectionView.isDecelerating
                || self.spring.isRunning || self.explainedMoves != movesAtLanding
            let shift = scrolling ? 0 : self.windowY(of: row.id, bottom: row.bottom).map { abs($0 - row.windowY) } ?? 0
            probe.pageLanded?(shift, rows)
        }
    }

    // MARK: Moving the offset

    /// A move the list makes on purpose (following the newest row, riding the bottom edge): the
    /// frame-shift measure counts it as explained.
    private func moveOffset(to y: CGFloat) {
        guard abs(collectionView.contentOffset.y - y) > 0.01 else { return }
        ownMoves += 1
        collectionView.contentOffset.y = y
        ownMoves -= 1
    }

    /// A move that cancels a shift (putting the reader back): not explained, so a correction that
    /// misses shows up in the measure.
    private func correctOffset(by delta: CGFloat) {
        corrections += 1
        collectionView.contentOffset.y += delta
        corrections -= 1
    }

    private var maxOffsetY: CGFloat {
        max(-collectionView.adjustedContentInset.top,
            collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height)
    }

    /// The offset at the newest end.
    private var newestOffset: CGFloat {
        direction == .up ? maxOffsetY : -collectionView.adjustedContentInset.top
    }

    /// How far the viewport is from the newest end (0 there).
    private var distanceToNewest: CGFloat {
        direction == .up ? maxOffsetY - collectionView.contentOffset.y : collectionView.contentOffset.y - newestOffset
    }

    private func scrollToNewest() {
        moveOffset(to: newestOffset)
    }

    /// Keeps an `.up` list that follows its newest row on it after a layout pass. Riding the bottom
    /// edge (the keyboard, a composer that grew) is the list's own move; the rest cancels what moved
    /// the newest row (a page or a row above that changed the content's height), a correction: the
    /// reader sees nothing move, so the shift measure counts nothing for it.
    private func stayOnNewest(edgeMove: CGFloat?) {
        // The edge moving up by d (d < 0) takes the rows up with it: an offset move of -d (or, for a
        // short list sitting on the edge, its top inset's).
        if let edgeMove { ledger.explain(-edgeMove) }
        let delta = newestOffset - collectionView.contentOffset.y
        guard abs(delta) > 0.01 else { return }
        correctOffset(by: delta)
    }

    /// The newest-rows indicator's jump: a windowed model brings its newest rows back first.
    private func jumpToNewest() {
        showNewest?()
        followsNewest = true
        newest.arrived = 0
        newest.isAway = false
        heldHeight = 0
        // A fling still running would drive the offset too: stop it where it is.
        if collectionView.isDecelerating { collectionView.setContentOffset(collectionView.contentOffset, animated: false) }
        if UIAccessibility.isReduceMotionEnabled || !animatesNewest {
            scrollToNewest()
        } else {
            spring.run(from: collectionView.contentOffset.y)
        }
    }

    /// The viewport's bottom edge in window coordinates (the keyboard, an accessory, a bar).
    private var bottomEdge: CGFloat {
        collectionView.convert(CGPoint(x: 0, y: collectionView.bounds.maxY - collectionView.adjustedContentInset.bottom), to: nil).y
    }

    /// While the reader scrolls (a finger or a fling), each layout pass keeps the row under the
    /// reader's top edge where it was drawn: a pass that moves it (rows above that changed height out
    /// of view, a window that moved) puts it back in the same pass. Between passes the scroll moves
    /// it, which is the scroll. Updates keep their own anchor; at rest `keepReader` keeps it.
    /// A `.down` list's slide to new rows at its top does the same: the rows it reveals above size
    /// themselves as they come into view, and must not push the rows below down (the spring carries
    /// the correction and slides on).
    private func willLayout() {
        passHold = nil
        // The cells as drawn sit against the offset before UIKit's corrections that this pass lays
        // out (rows above that sized outside a pass): holding them against the corrected offset
        // would correct a second time.
        let drawnOffset = ledger.takeDrawnOffset(collectionView.contentOffset.y)
        let scrolling = collectionView.isTracking || collectionView.isDecelerating
        let sliding = direction == .down && spring.isRunning
        guard loaded, !updating, !keeping, !laying,
              sliding || (scrolling && !followsNewest && !spring.isRunning) else { return }
        let top = drawnOffset + collectionView.adjustedContentInset.top
        var best: (id: CellID, minY: CGFloat)?
        // The cells as drawn: their frames are the last pass's (the layout may already hold the next).
        for cell in collectionView.visibleCells where cell.frame.maxY > top + 0.5 {
            guard best == nil || cell.frame.minY < best!.minY,
                  let indexPath = collectionView.indexPath(for: cell),
                  let id = dataSource.itemIdentifier(for: indexPath), case .row = id else { continue }
            best = (id, cell.frame.minY)
        }
        if let best { passHold = (best.id, best.minY - drawnOffset) }
    }

    private func holdAcrossPass() {
        guard let hold = passHold else { return }
        passHold = nil
        guard let indexPath = dataSource.indexPath(for: hold.id), let cell = collectionView.cellForItem(at: indexPath) else { return }
        let delta = (cell.frame.minY - collectionView.contentOffset.y) - hold.top
        if abs(delta) > 0.25 { correctOffset(by: delta) }
    }

    /// Each layout pass: a short `.up` list sits at the bottom; an `.up` list that follows its newest
    /// row stays on it (keyboard, rotation, a row that grew); otherwise the bottom edge's move is
    /// answered as `pinning` says, and the reader is kept.
    private func didLayout() {
        guard !keeping, !laying else {
            passHold = nil
            return
        }
        laying = true
        defer { laying = false }
        holdAcrossPass()
        let width = collectionView.bounds.width
        let edgeNow = collectionView.window == nil ? nil : bottomEdge
        let edgeMove: CGFloat? = {
            guard let edgeNow, let lastBottomEdge, abs(width - lastBoundsWidth) < 0.5, abs(edgeNow - lastBottomEdge) > 0.5 else { return nil }
            return edgeNow - lastBottomEdge
        }()
        defer {
            lastBoundsWidth = width
            lastBottomEdge = edgeNow
            sampleShift(from: "layout")
        }
        if direction == .up {
            let insets = collectionView.adjustedContentInset
            let room = collectionView.bounds.height - (insets.top - bottomGap) - insets.bottom
            let gap = max(0, (room - collectionView.contentSize.height).rounded(.down))
            if abs(gap - bottomGap) > 0.5 {
                // The gap first: changing the inset calls back into this pass.
                let change = gap - bottomGap
                bottomGap = gap
                collectionView.contentInset.top += change
            }
        }
        guard loaded, !collectionView.isTracking else {
            keepReader()
            return
        }
        if direction == .up, followsNewest {
            if !collectionView.isDecelerating, !spring.isRunning, !arriving { stayOnNewest(edgeMove: edgeMove) }
            kept = nil
        } else if let edgeMove, pinning == .ridesBottomEdge, !followsNewest, let kept, !keeping {
            // The bottom edge moved (the keyboard, a composer that grew): what the reader sees goes
            // with it, as in Messages.
            keeping = true
            restore(kept, shiftedBy: edgeMove, deliberate: true)
            keeping = false
            takePlace()
        } else {
            keepReader()
        }
    }

    private func textSizeChanged() {
        heights.removeAll()
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        keepReader()
        if followsNewest { scrollToNewest() }
    }

    // MARK: Measuring layout shift

    /// The frame-shift measure (``PagedListProbe/frameShift``): the row being read at the end of the
    /// last pass, where it is now, less what the scroll explains. Skipped across a rotation, and
    /// when that row left or moved (a removal or move is not a shift of what is read).
    private func sampleShift(from source: String) {
        guard !updating, let probe, probe.frameShift != nil || probe.passFrameShift != nil, loaded,
              collectionView.window != nil else { return }
        let width = collectionView.bounds.width
        querying += 1
        let current = referenceRow()
        querying -= 1
        let offsetY = collectionView.contentOffset.y
        let frame = listFrame
        let lastFrame = passFrame
        defer {
            passFrame = frame
            shiftSample = current.map { ShiftSample(id: $0.id, next: $0.next, gap: $0.gap, bottom: $0.bottom, windowY: $0.windowY, width: width, offsetY: offsetY) }
            if probe.shiftDetail != nil {
                previousInterval = PagedListPreviousInterval(source: source, trail: trail, pending: ledger.pending)
            }
            ledger.reset()
            trail.removeAll(keepingCapacity: true)
        }
        guard let last = shiftSample, abs(last.width - width) < 0.5,
              let indexPath = dataSource.indexPath(for: last.id), let now = windowY(of: last.id, bottom: last.bottom) else { return }
        if let next = last.next, let gap = last.gap {
            guard let nextPath = dataSource.indexPath(for: next), nextPath.item - indexPath.item == gap else { return }
        }
        let shift = (now - last.windowY) + ledger.explained
        guard let report = probe.passFrameShift else { return }
        // The list's own window frame moved since the last pass, or differs from the last committed
        // frame's: one of the two passes saw it mid-placement (before the first commit too).
        let movedSincePass = lastFrame.map { $0 != frame } ?? false
        let movedSinceCommit = committedFrame.map { $0 != frame } ?? false
        let lastPassOffCommit = lastFrame.flatMap { last in committedFrame.map { last != $0 } } ?? false
        let midPlacement = movedSincePass || movedSinceCommit || lastPassOffCommit
        report(shift, midPlacement, abs(shift) > 0.5
            ? shiftDetail(at: source, moved: now - last.windowY, explained: ledger.explained, offset: offsetY - last.offsetY, frame: frame)
            : nil)
    }

    /// The frame-shift measure (``PagedListProbe/frameShift``) at each committed frame, what the
    /// screen shows: the row being read in the last committed frame, where it is in this one, less
    /// what the scroll explains in between. A layout pass can run while the list is mid-placement
    /// (SwiftUI gives the collection its bounds before its center): that never draws, so only the
    /// committed frames count. Skipped as the pass measure skips (a rotation, the row left or moved).
    private func timedSampleCommitted() {
        sampleDrawn()
        guard let cost = probe?.samplerCost else { return sampleCommitted() }
        let start = CACurrentMediaTime()
        sampleCommitted()
        cost((CACurrentMediaTime() - start) * 1000)
    }

    private func sampleCommitted() {
        guard !updating, let probe, let report = probe.frameShift, loaded, collectionView.window != nil else { return }
        let width = collectionView.bounds.width
        querying += 1
        let current = committedReferenceRow()
        querying -= 1
        let offsetY = collectionView.contentOffset.y
        let frame = listFrame
        committedFrames += 1
        if probe.shiftDetail != nil {
            let nextY = current?.next.flatMap { windowY(of: $0, bottom: false) }
            if drawnFrames.count == 6 { drawnFrames.removeFirst() }
            drawnFrames.append(DrawnFrame(number: committedFrames, read: current?.windowY ?? .nan, next: nextY ?? .nan,
                                          offset: offsetY, explained: ledger.committedExplained, spring: spring.isRunning,
                                          trail: commitTrail))
        }
        let bottom = current?.bottom ?? false
        func rowsOnScreen(bottom: Bool) -> [PagedListFollow.Row<CellID>] {
            collectionView.indexPathsForVisibleItems.sorted().compactMap { indexPath in
                guard let id = dataSource.itemIdentifier(for: indexPath), case .row = id,
                      let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
                return .init(id: id, y: windowY(attributes, bottom: bottom))
            }
        }
        let visible = rowsOnScreen(bottom: bottom)
        // Now, as the last sample read its rows (their tops, or bottoms), with the row read then
        // where the layout has it now, also off screen (after the rows on screen, so its place among
        // them says it left them).
        var rows = committedSample.map { $0.bottom == bottom ? visible : rowsOnScreen(bottom: $0.bottom) } ?? visible
        if let last = committedSample, !rows.contains(where: { $0.id == last.id }), let y = windowY(of: last.id, bottom: last.bottom) {
            rows.append(.init(id: last.id, y: y))
        }
        defer {
            committedRows = visible
            committedSample = current.map { ShiftSample(id: $0.id, next: $0.next, gap: $0.gap, bottom: $0.bottom, windowY: $0.windowY, width: width, offsetY: offsetY) }
            committedFrame = frame
            ledger.resetCommitted()
            commitTrail.removeAll(keepingCapacity: true)
        }
        guard let last = committedSample, abs(last.width - width) < 0.5,
              let followed = PagedListFollow.pick(previous: committedRows, current: rows, reading: last.id) else { return }
        let was = followed.was
        let now = followed.now
        let shift = (now - was) + ledger.committedExplained
        report(shift)
        if abs(shift) > 0.5, let detail = probe.shiftDetail {
            detail(shift, shiftDetail(at: "commit", moved: now - was, explained: ledger.committedExplained,
                                      offset: offsetY - last.offsetY, frame: frame)
                + " frames=" + drawnFrames.map { f in
                    String(format: "#%d[read=%.1f next=%.1f off=%.1f expl=%+.1f spring=%d ", f.number, f.read, f.next,
                           f.offset, f.explained, f.spring ? 1 : 0) + f.trail.map(\.text).joined(separator: ",") + "]"
                }.joined(separator: " "))
        }
    }

    /// The row the committed-frame measure follows: as ``referenceRow()``, but for a list read from
    /// its top, the first row whose top is in view (at or below the reader's top edge). A row cut by
    /// that edge that changes height keeps its bottom where it was (``PagedListLayout`` corrects the
    /// offset for it, as for any row above), so its top moves while nothing the reader sees does:
    /// following it counted a row growing under the bars as a shift (up-medium-flood 44 pt and
    /// up-slow-flood 22 pt, steps 6d8bcee4 and f902d4d6, with the next row still to the point).
    private func committedReferenceRow() -> (id: CellID, next: CellID?, gap: Int?, bottom: Bool, windowY: CGFloat)? {
        guard direction != .up || !followsNewest else { return referenceRow() }
        let top = readerTop
        var found: (CellID, Int, CGFloat)?
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                  attributes.frame.minY >= top - 0.5,
                  let id = dataSource.itemIdentifier(for: indexPath), case .row = id else { continue }
            if let first = found {
                return (first.0, id, indexPath.item - first.1, false, first.2)
            }
            found = (id, indexPath.item, windowY(attributes))
        }
        return found.map { ($0.0, nil, nil, false, $0.2) }
    }

    /// The drawn measure (``PagedListProbe/drawnShift``): reads each row on screen's top from its
    /// cell's presentation layer, in the window's presentation space, once per committed frame.
    private func sampleDrawn() {
        guard let report = probe?.drawnShift, loaded, !updating, let window = collectionView.window else {
            drawnRows = []
            drawnHeights = [:]
            return
        }
        let windowLayer = window.layer.presentation() ?? window.layer
        var rows: [(id: CellID, y: CGFloat)] = []
        var heights: [CellID: CGFloat] = [:]
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard let id = dataSource.itemIdentifier(for: indexPath), case .row = id,
                  let cell = collectionView.cellForItem(at: indexPath) else { continue }
            let layer = cell.layer.presentation() ?? cell.layer
            rows.append((id, layer.convert(CGPoint(x: 0, y: layer.bounds.minY), to: windowLayer).y))
            heights[id] = layer.bounds.height
        }
        querying += 1
        let reading = referenceRow()?.id
        querying -= 1
        let explained = ledger.committedExplained
        let previousHeights = drawnHeights
        defer { drawnRows = rows; drawnReading = reading; drawnHeights = heights }
        guard !drawnRows.isEmpty else { return }
        if let neighbours = probe?.neighbourShift,
           let worst = PagedListFollow.neighbourShift(
               previous: drawnRows.map { PagedListFollow.Drawn(id: $0.id, y: $0.y, height: previousHeights[$0.id] ?? 0) },
               current: rows.map { PagedListFollow.Drawn(id: $0.id, y: $0.y, height: heights[$0.id] ?? 0) },
               reading: drawnReading, explained: explained) {
            neighbours(worst.shift, abs(worst.shift) > 0.5 && probe?.shiftDetail != nil
                ? String(format: "neighbour row=%@ shift=%.1f explained=%.1f reading=%@", String(describing: worst.id), worst.shift,
                         explained, String(describing: drawnReading))
                : nil)
        }
        // The same choice of row as the committed-frame measure (``PagedListFollow``).
        guard let followed = PagedListFollow.pick(previous: drawnRows.map { PagedListFollow.Row(id: $0.id, y: $0.y) },
                                                  current: rows.map { PagedListFollow.Row(id: $0.id, y: $0.y) },
                                                  reading: drawnReading) else { return }
        let shift = (followed.now - followed.was) + explained
        let detail = abs(shift) > 0.5 && probe?.shiftDetail != nil
            ? String(format: "drawn moved=%.1f explained=%.1f row=%@ followed=%@", followed.now - followed.was, explained,
                     String(describing: followed.id), followed.id == drawnReading ? "reading" : "survivor")
            : nil
        report(shift, detail)
    }

    /// The list's frame in its window (a container that moves it moves what is read).
    private var listFrame: CGRect { collectionView.convert(collectionView.bounds, to: nil) }

    private func shiftDetail(at source: String, moved: CGFloat, explained: CGFloat, offset: CGFloat, frame: CGRect) -> String {
        let insets = collectionView.adjustedContentInset
        return "from=\(source) moved=\(moved) explained=\(explained) offset=\(offset) "
            + "pending=\(ledger.pending) follows=\(followsNewest) tracking=\(collectionView.isTracking) "
            + "decelerating=\(collectionView.isDecelerating) spring=\(spring.isRunning) arriving=\(arriving) "
            + "insetTop=\(insets.top) insetBottom=\(insets.bottom) gap=\(bottomGap) rows=\(order.count) "
            + String(format: "list=%.0f,%.0f ", frame.minX, frame.minY)
            + "trail=\(trail.map(\.text).joined(separator: ",")) prev=\(previousInterval.text)"
    }

    /// One offset move or layout correction for the probe's detail: its kind, the move, and `^` when
    /// it came inside another scroll callback.
    /// Kept as numbers, formatted only when a shift's detail is written (each offset move formatted
    /// a string on a busy main thread: up-fast-busy 5.3 to 66.7 ms/s of hitches, clean reps
    /// 4c5f3bf8..4487071f).
    private func note(_ kind: String, _ delta: CGFloat) {
        guard probe?.shiftDetail != nil else { return }
        let nested = kind.hasPrefix("A") ? scrollDepth > 0 : scrollDepth > 1
        let entry = PagedListTrailNote(kind: kind, delta: delta, nested: nested)
        if commitTrail.count < 32 { commitTrail.append(entry) }
        guard trail.count < 24 else { return }
        trail.append(entry)
    }

    /// The row the measure follows: the one the list keeps still. The one being read (its top), or,
    /// for an `.up` list at its newest row, the lowest row on screen (its bottom: the list keeps that
    /// on the bottom edge, and a row there that grows grows upward).
    private func referenceRow() -> (id: CellID, next: CellID?, gap: Int?, bottom: Bool, windowY: CGFloat)? {
        guard direction == .up, followsNewest else { return firstReadable() }
        let bottom = bottomEdgeY
        var found: (CellID, Int, CGFloat)?
        for indexPath in collectionView.indexPathsForVisibleItems.sorted().reversed() {
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                  attributes.frame.minY < bottom - 0.5,
                  let id = dataSource.itemIdentifier(for: indexPath), case .row = id else { continue }
            if let first = found {
                return (first.0, id, indexPath.item - first.1, true, first.2)
            }
            found = (id, indexPath.item, windowY(attributes, bottom: true))
        }
        return found.map { ($0.0, nil, nil, true, $0.2) }
    }

    private func firstReadable() -> (id: CellID, next: CellID?, gap: Int?, bottom: Bool, windowY: CGFloat)? {
        let top = readerTop
        var found: (CellID, Int, CGFloat)?
        for indexPath in collectionView.indexPathsForVisibleItems.sorted() {
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                  attributes.frame.maxY > top + 0.5,
                  let id = dataSource.itemIdentifier(for: indexPath), case .row = id else { continue }
            if let first = found {
                return (first.0, id, indexPath.item - first.1, false, first.2)
            }
            found = (id, indexPath.item, windowY(attributes))
        }
        return found.map { ($0.0, nil, nil, false, $0.2) }
    }

    // MARK: Reading ahead

    /// The next page is asked for while the reader is within `readAheadScreens` of the edge, so a
    /// fling meets rows, not a spinner. Checked on every scroll step and after every update (a page
    /// that leaves the reader near the edge asks for the next). The newer edge of a windowed model
    /// reads back from disk the same way.
    private func queueReadAhead() {
        guard !readAheadQueued else { return }
        readAheadQueued = true
        Task { @MainActor [weak self] in
            self?.readAheadQueued = false
            self?.readAheadIfNear()
        }
    }

    private func readAheadIfNear() {
        guard loaded, collectionView.bounds.height > 0 else { return }
        if edge == .more, collectionView.pagedScreensToEdge(direction) < readAheadScreens { loadMore() }
        if newerEdge == .more, collectionView.pagedScreensToNewest(direction) < readAheadScreens { loadNewer() }
    }

    /// Pull to refresh at the top of a `.down` list (nil: none).
    func setRefresh(_ action: (() async -> Void)?) {
        refreshAction = action
        if action != nil, direction == .down, pullToRefresh == nil {
            pullToRefresh = ListPullToRefresh(scrollView: collectionView) { [weak self] in await self?.refreshAction?() }
            collectionView.accessibilityRefresh = { [weak self] in self?.pullToRefresh?.accessibilityRefresh() ?? false }
        } else if action == nil, let pullToRefresh {
            pullToRefresh.detach()
            self.pullToRefresh = nil
            collectionView.accessibilityRefresh = nil
        }
    }

    // MARK: Prefetching

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let prefetch else { return }
        let rows = rowItems(at: indexPaths)
        if !rows.isEmpty { prefetch(rows) }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        guard let cancelPrefetch else { return }
        let rows = rowItems(at: indexPaths)
        if !rows.isEmpty { cancelPrefetch(rows) }
    }

    private func rowItems(at indexPaths: [IndexPath]) -> [Item] {
        indexPaths.compactMap { indexPath in
            guard case .row(let id)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return items[id]
        }
    }

    // MARK: Scrolling

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        pullToRefresh?.willEndDragging(targetContentOffset: targetContentOffset)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scrollDepth += 1
        defer { scrollDepth -= 1 }
        let y = scrollView.contentOffset.y
        let delta = y - lastOffsetY
        lastOffsetY = y
        let userMove = scrollView.isTracking || scrollView.isDecelerating || scrollingToTop
        let personMoves = (scrollView.isTracking || scrollView.isDecelerating) && corrections == 0 && ownMoves == 0
            && !updating && collectionView.laying == 0 && collectionView.layingLayer == 0 && !spring.isRunning
        if corrections > 0 {
            // Putting the reader back: not part of the scroll.
            note("c", delta)
        } else if ownMoves > 0 {
            ledger.explain(delta)
            explainedMoves += 1
            note("o", delta)
        } else if updating || collectionView.laying > 0 || collectionView.layingLayer > 0 {
            // Inside an update or a layout pass: the layout's or UIKit's own move (a row above
            // that sized itself, a batch update), never the finger or a fling, which move the
            // offset between passes.
            note(updating ? "U" : collectionView.laying > 0 ? "L" : "S", delta)
        } else if ledger.pays(delta) {
            // The layout's own correction for a row above that changed height (UIKit may apply
            // several rows' corrections one at a time or together).
            note("p", delta)
        } else if userMove {
            explainedMoves += 1
            let kind = (querying > 0 ? "Q" : "") + (scrollView.isDragging ? "d" : scrollView.isTracking ? "t" : "u")
            if let request = collectionView.offsetRequest {
                // The set asked for the finger's or the fling's step; what it moved beyond that is
                // UIKit's (once per set: a callback nested in the same set is all UIKit's).
                let person = request.serial == countedRequest ? 0 : request.y - request.from
                countedRequest = request.serial
                ledger.explain(person)
                note(kind, person)
                if abs(delta - person) > 0.01 { note("K", delta - person) }
            } else {
                ledger.explain(delta)
                note(kind, delta)
            }
        } else {
            note("n", delta)
        }
        pullToRefresh?.scrolled()
        // Only the person's moves decide whether the list follows its newest row: the list's own
        // slide or a correction under a resting finger is not them leaving it.
        if personMoves {
            deriveFollowing()
            if onReading != nil, let id = readingRowID() { report(id) }
        }
        updateAway()
        readAheadIfNear()
    }

    /// Whether the list follows its newest row, from where the reader is now.
    private func deriveFollowing() {
        let wasFollowing = followsNewest
        // At the end of the rows shown is the newest row only when the list holds it: a windowed
        // list's newer-edge spinner is not followed (its rows come from disk, not live).
        followsNewest = distanceToNewest - heldHeight <= 4 && newerEdge == .end
        if !followsNewest { heldHeight = 0 }
        if followsNewest, !wasFollowing { newest.arrived = 0 }
    }

    /// A scroll made with no finger and no fling ended (a VoiceOver page scroll, an animated set of
    /// the offset): it decides following as the person's own scroll does, and the reader's place is
    /// taken where it ended. Without it a list scrolled a page away from its newest row by VoiceOver
    /// still followed it, and the next row to arrive took the reader back there. Not the list's own
    /// moves (the spring's slide, a correction) or the status bar's scroll to top, which decide
    /// following themselves.
    func scrollEndedByCode() {
        guard loaded, !spring.isRunning, !scrollingToTop, !collectionView.isTracking, !collectionView.isDecelerating else { return }
        deriveFollowing()
        if onReading != nil, let id = readingRowID() { report(id) }
        updateAway()
        takePlace()
    }

    /// The row under the reader's top edge, by a hit test (cheap enough for every scroll step).
    private func readingRowID() -> Item.ID? {
        let point = CGPoint(x: collectionView.bounds.midX, y: readerTop + 1)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              case .row(let id)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return id
    }

    /// The indicator's "away" state, with hysteresis: away past half a screen, back within a quarter.
    private func updateAway() {
        let screen = collectionView.bounds.height
        guard screen > 0 else { return }
        let distance = collectionView.pagedScreensToNewest(direction)
        let away = newest.isAway ? distance > 0.25 : distance > 0.5
        if away != newest.isAway { newest.isAway = away }
        if !away, newest.arrived != 0, followsNewest { newest.arrived = 0 }
    }

    /// The top inset moves at runtime (a banner, a search drawer), or the bottom one (an accessory,
    /// the keyboard): the refresh indicator follows it and the rows answer it as in a layout pass.
    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        pullToRefresh?.scrolled()
        didLayout()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The person's finger wins over the list's own slide; rows held for it count as new.
        spring.stop()
        if heldArrivals > 0 {
            newest.arrived += heldArrivals
            heldArrivals = 0
        }
        probe?.scrolling?(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settleOnNewest()
            takePlace()
            probe?.scrolling?(false)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        pullToRefresh?.endedDecelerating()
        settleOnNewest()
        takePlace()
        probe?.scrolling?(false)
    }

    /// A scroll that ends at the newest end, after rows arrived there under the finger (they landed
    /// out of view): the list slides on to them. Not from a pull past the top of a `.down` list
    /// (pull to refresh owns that).
    private func settleOnNewest() {
        let offset = collectionView.contentOffset.y
        guard loaded, followsNewest, !spring.isRunning, abs(newestOffset - offset) > 0.5,
              direction == .up || offset > newestOffset else { return }
        if animatesNewest, !UIAccessibility.isReduceMotionEnabled {
            spring.run(from: collectionView.contentOffset.y)
        } else {
            scrollToNewest()
        }
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        spring.stop()
        if heldArrivals > 0 {
            newest.arrived += heldArrivals
            heldArrivals = 0
        }
        heldHeight = 0
        scrollingToTop = true
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        scrollingToTop = false
        followsNewest = direction == .down
        if followsNewest { newest.arrived = 0 }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        let toTop = scrollingToTop
        scrollingToTop = false
        if toTop { takePlace() } else { scrollEndedByCode() }
    }

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

/// Runs `sample` once per display frame, after Core Animation commits it: a display link marks each
/// frame due, and the first main run loop turn after it samples (its observer runs after the commit
/// observer at order 2000000, before the loop waits). Once per frame, not per turn: a busy main
/// thread turns the loop many times a frame (the up-fast-busy stress case's hitches rose 8.7 to 70
/// ms/s when it sampled every turn, steps 87db292d and 57fdbd67).
@MainActor
final class PagedListCommitWatch {
    // Invalidating a run loop observer is safe from any thread.
    nonisolated(unsafe) private let observer: CFRunLoopObserver
    private let tick = PagedListCommitTick()
    nonisolated(unsafe) private var token: FrameClock.Token?

    init(_ sample: @escaping @MainActor () -> Void) {
        let tick = tick
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 2_000_100) { _, _ in
            MainActor.assumeIsolated {
                guard tick.due else { return }
                tick.due = false
                sample()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // The app's one display link (``FrameClock``), not a second one of its own.
        token = FrameClock.shared.subscribe { _ in tick.due = true }
    }

    deinit {
        CFRunLoopObserverInvalidate(observer)
        if let token { Task { @MainActor in FrameClock.shared.unsubscribe(token) } }
    }
}

/// Marks a frame due (the clock's tick), read by the run loop observer after the commit.
@MainActor
private final class PagedListCommitTick {
    var due = false
}

/// One offset move or correction for the probe's detail, kept as numbers (formatted only for a detail).
struct PagedListTrailNote {
    let kind: String
    let delta: CGFloat
    let nested: Bool
    var text: String { "\(kind)\(nested ? "^" : "")\(String(format: "%+.1f", delta))" }
}

/// The previous layout-pass interval for the probe's detail, kept as numbers.
struct PagedListPreviousInterval {
    var source = ""
    var trail: [PagedListTrailNote] = []
    var pending: CGFloat = 0
    var text: String { source.isEmpty ? "" : "\(source):\(trail.map(\.text).joined(separator: ","))/pending=\(pending)" }
}
