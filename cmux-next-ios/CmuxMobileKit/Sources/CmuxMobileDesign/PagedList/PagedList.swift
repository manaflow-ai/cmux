#if os(iOS)
import CmuxSpinner
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// The one infinite-scroll list for the iPhone app (verify/paged-list.md): pages load as the reader
/// scrolls down (`.down`: the Feed, chat lists, workspaces) or up (`.up`: a chat's history, which
/// opens at its newest row at the bottom). Rows are SwiftUI; the list under them is UIKit's
/// (`PagedListController`), which reads ahead of the reader, never moves what they read when a page
/// or a live row lands, keeps an `.up` list on its newest row through the keyboard and new rows,
/// and draws the first page's loading, failure and empty states and the edge's spinner, Try Again
/// and end.
///
/// Drive it from a ``PagedListModel``, or from a screen's own model (items, phase, edge, and the
/// two actions). Options: a bottom accessory pinned to the keyboard (any view), how the rows answer
/// the bottom edge moving, a newest-rows indicator drawn by the screen, prefetching, and whether new
/// rows at the newest end slide in.
public struct PagedList<Item: Identifiable & Equatable, Row: View, Empty: View>: View where Item.ID: Sendable {
    let direction: PagedListDirection
    let items: [Item]
    let phase: PagedListPhase
    let edge: PagedListEdge
    let loadMore: @MainActor () -> Void
    let retry: @MainActor () async -> Void
    let row: (Item) -> Row
    let empty: () -> Empty
    var swipeActions: ((Item) -> [PagedListAction])?
    var fullSwipe = true
    var header: Set<Item.ID> = []
    var endLabel: LocalizedStringKey?
    var loadingLabel: LocalizedStringKey = "Loading…"
    var failureTitle: LocalizedStringKey = "Couldn't load"
    var identifier = "pagedList"
    var probe: PagedListProbe?
    var cachesHeights = true
    var refresh: (@MainActor () async -> Void)?
    var newerEdge: PagedListEdge = .end
    var loadNewer: (@MainActor () -> Void)?
    var onReading: (@MainActor (Item.ID) -> Void)?
    var showNewest: (@MainActor () -> Void)?
    var beyondWindow = 0
    var accessory: (() -> AnyView)?
    var accessoryBackground: AnyShapeStyle?
    var followsKeyboard = true
    var pinning: PagedListBottomPinning?
    var indicator: ((PagedListNewest) -> AnyView)?
    var animatesNewest = true
    var prefetch: (([Item]) -> Void)?
    var cancelPrefetch: (([Item]) -> Void)?

    public init(
        direction: PagedListDirection,
        items: [Item],
        phase: PagedListPhase,
        edge: PagedListEdge,
        loadMore: @escaping @MainActor () -> Void,
        retry: @escaping @MainActor () async -> Void,
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder empty: @escaping () -> Empty
    ) {
        self.direction = direction
        self.items = items
        self.phase = phase
        self.edge = edge
        self.loadMore = loadMore
        self.retry = retry
        self.row = row
        self.empty = empty
    }

    public var body: some View {
        if accessory != nil || indicator != nil {
            // UIKit lays out the rows, the accessory and the keyboard together: the host takes the
            // whole height and insets the rows itself.
            let host = PagedListHostRepresentable(config: config, overlay: overlay, accessory: accessory?(),
                                                  accessoryBackground: accessoryBackground, followsKeyboard: followsKeyboard,
                                                  indicator: indicator)
            if accessory != nil {
                // The host reaches the screen's bottom edge, under the keyboard: UIKit puts the
                // accessory on the keyboard and insets the rows by it. The top keeps the screen's
                // safe area (its bars, a banner), as the plain list does.
                host.ignoresSafeArea(.keyboard).ignoresSafeArea(.container, edges: .bottom)
            } else {
                // Only an indicator: laid out as the plain list (a bar the screen puts under the
                // list with `safeAreaInset` insets the rows).
                host
            }
        } else {
            plain
        }
    }

    /// The first page's state, over the rows of a list with an accessory (nil: the rows show).
    private var overlay: AnyView? {
        switch phase {
        case .loading where items.isEmpty: AnyView(loadingState)
        case .failed(let message) where items.isEmpty: AnyView(failedState(message))
        default: items.isEmpty && edge == .end ? AnyView(emptyState) : nil
        }
    }

    private var loadingState: some View {
        CmuxSpinner(label: Text(loadingLabel))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifier).loading")
    }

    private func failedState(_ message: String) -> some View {
        // The read replaces this state at once (a spinner), which would cancel a task owned by
        // the button: the retry runs unowned.
        EmptyState(symbol: "exclamationmark.triangle", title: failureTitle, message: "\(message)",
                   retry: { [retry] in Task { await retry() } })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifier).failed")
    }

    private var config: PagedListConfig<Item, Row> {
        PagedListConfig(direction: direction, items: items, edge: edge, newerEdge: newerEdge, loadMore: loadMore,
                        loadNewer: loadNewer, retry: retry, row: row, swipeActions: swipeActions, fullSwipe: fullSwipe,
                        header: header, endLabel: endLabel,
                        identifier: identifier, probe: probe, cachesHeights: cachesHeights, refresh: refresh,
                        onReading: onReading, showNewest: showNewest, beyondWindow: beyondWindow, pinning: pinning,
                        animatesNewest: animatesNewest, prefetch: prefetch, cancelPrefetch: cancelPrefetch)
    }

    @ViewBuilder private var plain: some View {
        switch phase {
        case .loading where items.isEmpty:
            loadingState
        case .failed(let message) where items.isEmpty:
            failedState(message)
        default:
            if items.isEmpty, edge == .end {
                if let refresh {
                    // An empty list still refreshes: a row that appears later (a chat archived on
                    // the Mac) is one pull away, as it was with the old List's `.refreshable`.
                    ScrollView {
                        emptyState.containerRelativeFrame([.horizontal, .vertical])
                    }
                    .refreshable { await refresh() }
                } else {
                    emptyState
                }
            } else {
                PagedListRepresentable(config: config)
            }
        }
    }

    private var emptyState: some View {
        empty()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifier).empty")
    }

    /// Trailing swipe actions per row (UIKit's swipe; the first is the full swipe's, unless
    /// `allowsFullSwipe` is false: then a full swipe runs none, as SwiftUI's `allowsFullSwipe: false`).
    public func pagedSwipeActions(allowsFullSwipe: Bool = true, _ actions: @escaping (Item) -> [PagedListAction]) -> Self {
        var copy = self
        copy.swipeActions = actions
        copy.fullSwipe = allowsFullSwipe
        return copy
    }

    /// Items that head a `.down` list (a grid of pins, a status card above the rows): they are not
    /// its newest rows, so a row that lands under them, at the top of the rows, arrives (it slides
    /// in at the top, or counts on the newest-rows indicator while the reader is away).
    public func pagedHeader(_ ids: Set<Item.ID>) -> Self {
        var copy = self
        copy.header = ids
        return copy
    }

    /// The label at the edge once the oldest row shows (none by default).
    public func pagedEndLabel(_ label: LocalizedStringKey?) -> Self {
        var copy = self
        copy.endLabel = label
        return copy
    }

    /// The first page's loading label and failure title.
    public func pagedLabels(loading: LocalizedStringKey, failure: LocalizedStringKey) -> Self {
        var copy = self
        copy.loadingLabel = loading
        copy.failureTitle = failure
        return copy
    }

    /// The accessibility identifier of the list (`<id>`), its states (`<id>.loading`, `.failed`,
    /// `.empty`) and its edge (`<id>.edge.more|loading|failed|end`).
    public func pagedIdentifier(_ identifier: String) -> Self {
        var copy = self
        copy.identifier = identifier
        return copy
    }

    /// What a lab or test learns as the list works.
    public func pagedProbe(_ probe: PagedListProbe?) -> Self {
        var copy = self
        copy.probe = probe
        return copy
    }

    /// Pull to refresh at the top of a `.down` list (SwiftUI's `.refreshable` does not reach the
    /// UIKit list under the rows).
    public func pagedRefresh(_ action: @escaping @MainActor () async -> Void) -> Self {
        var copy = self
        copy.refresh = action
        return copy
    }

    /// Off for rows whose height depends on state outside the item (they are measured each time).
    public func pagedCachesHeights(_ caches: Bool) -> Self {
        var copy = self
        copy.cachesHeights = caches
        return copy
    }

    /// Pins `accessory` (any view: a composer, a reply bar, a toolbar) to the list's bottom: it rides
    /// the keyboard (in the keyboard's own animation, and with the finger as the keyboard is dragged
    /// down) unless `followsKeyboard` is false, and the list's bottom edge is its top, so the rows go
    /// up with it as ``pagedBottomPinning(_:)`` says. It stays (with its focus) through the first
    /// page's states. The accessory gets no environment from the screen: pass it what it reads.
    public func pagedBottomAccessory(followsKeyboard: Bool = true, @ViewBuilder _ accessory: @escaping () -> some View) -> Self {
        var copy = self
        copy.accessory = { AnyView(accessory()) }
        copy.followsKeyboard = followsKeyboard
        copy.accessoryBackground = nil
        return copy
    }

    /// ``pagedBottomAccessory(followsKeyboard:_:)`` on a `background` that reaches from the
    /// accessory's top to the screen's bottom edge (under the home indicator, and behind the
    /// keyboard as it moves), as a chat's composer bar does. Without one, the rows show under the
    /// accessory and below it (a floating composer).
    public func pagedBottomAccessory(followsKeyboard: Bool = true, background: some ShapeStyle,
                                     @ViewBuilder _ accessory: @escaping () -> some View) -> Self {
        var copy = pagedBottomAccessory(followsKeyboard: followsKeyboard, accessory)
        copy.accessoryBackground = AnyShapeStyle(background)
        return copy
    }

    /// How the rows answer the list's bottom edge moving (the keyboard, an accessory that grows, a
    /// bar under the list). Default: `.ridesBottomEdge` for `.up`, `.keepsRows` for `.down`.
    public func pagedBottomPinning(_ pinning: PagedListBottomPinning) -> Self {
        var copy = self
        copy.pinning = pinning
        return copy
    }

    /// A newest-rows indicator the screen draws (none by default): what it gets says how many rows
    /// arrived at the newest end since the reader left it, whether the reader is away, and how to
    /// jump back. ``PagedListNewestPill`` is a ready-made one.
    public func pagedNewestIndicator(@ViewBuilder _ indicator: @escaping (PagedListNewest) -> some View) -> Self {
        var copy = self
        copy.indicator = { AnyView(indicator($0)) }
        return copy
    }

    /// Rows about to come into view (`prefetch`) and rows that no longer will (`cancel`), from
    /// UIKit's prefetching: start their images or other slow data ahead of the reader.
    public func pagedPrefetch(_ prefetch: @escaping ([Item]) -> Void, cancel: (([Item]) -> Void)? = nil) -> Self {
        var copy = self
        copy.prefetch = prefetch
        copy.cancelPrefetch = cancel
        return copy
    }

    /// New rows at the newest end slide in while the reader is there (on by default; Reduce Motion
    /// always puts them in place at once).
    public func pagedAnimatesNewest(_ animates: Bool) -> Self {
        var copy = self
        copy.animatesNewest = animates
        return copy
    }
}

extension PagedList where Empty == EmptyView {
    public init(
        direction: PagedListDirection,
        items: [Item],
        phase: PagedListPhase,
        edge: PagedListEdge,
        loadMore: @escaping @MainActor () -> Void,
        retry: @escaping @MainActor () async -> Void,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.init(direction: direction, items: items, phase: phase, edge: edge, loadMore: loadMore, retry: retry, row: row) { EmptyView() }
    }
}

extension PagedList where Item: Sendable {
    /// A list over a ``PagedListModel``. The screen reads the first page (`.task { await model.loadFirst() }`).
    public init(
        _ model: PagedListModel<Item>,
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder empty: @escaping () -> Empty
    ) {
        self.init(direction: model.direction, items: model.items, phase: model.phase, edge: model.edge,
                  loadMore: { Task { await model.loadMore() } }, retry: { await model.retry() }, row: row, empty: empty)
        newerEdge = model.newerEdge
        loadNewer = { model.loadNewer() }
        onReading = { model.reading($0) }
        showNewest = { model.showNewest() }
        beyondWindow = model.unseenNewest
    }
}

/// The edge's row: a spinner while more pages exist (the reader rarely reaches it: the page is read
/// two screens ahead), Try Again after a failure, and the end label. One height for the spinner and
/// the end, so the edge changing state moves nothing.
struct PagedListEdgeView: View {
    let edge: PagedListEdge
    var end: PagedListEnd = .older
    let endLabel: LocalizedStringKey?
    let identifier: String
    let retry: @MainActor () async -> Void

    var body: some View {
        let framed = states
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
        Group {
            if spins {
                // The spinner is a UIKit view with nothing for VoiceOver: the edge itself is the
                // element, so it is read ("Loading more") and found by its identifier.
                framed
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Loading more"))
            } else {
                framed.accessibilityElement(children: .contain)
            }
        }
        .accessibilityIdentifier("\(identifier).\(end == .older ? "edge" : "newer").\(stateName)")
    }

    private var spins: Bool {
        switch edge {
        case .more, .loading: true
        case .failed, .end: false
        }
    }

    @ViewBuilder private var states: some View {
        Group {
            switch edge {
            case .more, .loading:
                CmuxSpinner()
                    .controlSize(.small)
            case .failed(let message):
                VStack(spacing: 6) {
                    Text(message)
                        .font(theme.type.rowSubtitle)
                        .foregroundStyle(theme.colors.label2.color)
                        .multilineTextAlignment(.center)
                    // The edge turns into a spinner as the read starts, which would cancel a task
                    // owned by the button: the retry runs unowned.
                    RetryButton("Try Again", style: .inline, action: { [retry] in Task { await retry() } })
                        .accessibilityIdentifier("\(identifier).retry")
                }
                .padding(.vertical, 8)
            case .end:
                if let endLabel {
                    Text(endLabel)
                        .font(theme.type.rowSubtitle)
                        .foregroundStyle(theme.colors.label2.color)
                }
            }
        }
    }

    private var stateName: String {
        switch edge {
        case .more: "more"
        case .loading: "loading"
        case .failed: "failed"
        case .end: "end"
        }
    }
}

/// Everything the UIKit side reads from a ``PagedList`` on each update.
struct PagedListConfig<Item: Identifiable & Equatable, Row: View> where Item.ID: Sendable {
    let direction: PagedListDirection
    let items: [Item]
    let edge: PagedListEdge
    let newerEdge: PagedListEdge
    let loadMore: @MainActor () -> Void
    let loadNewer: (@MainActor () -> Void)?
    let retry: @MainActor () async -> Void
    let row: (Item) -> Row
    let swipeActions: ((Item) -> [PagedListAction])?
    let fullSwipe: Bool
    let header: Set<Item.ID>
    let endLabel: LocalizedStringKey?
    let identifier: String
    let probe: PagedListProbe?
    let cachesHeights: Bool
    let refresh: (@MainActor () async -> Void)?
    let onReading: (@MainActor (Item.ID) -> Void)?
    let showNewest: (@MainActor () -> Void)?
    let beyondWindow: Int
    let pinning: PagedListBottomPinning?
    let animatesNewest: Bool
    let prefetch: (([Item]) -> Void)?
    let cancelPrefetch: (([Item]) -> Void)?

    @MainActor
    func makeController() -> PagedListController<Item, Row> {
        let controller = PagedListController(direction: direction, row: row, edgeView: { _, _ in AnyView(EmptyView()) })
        controller.collectionView.accessibilityIdentifier = identifier
        return controller
    }

    @MainActor
    func apply(to controller: PagedListController<Item, Row>) {
        controller.row = row
        let endLabel = endLabel
        let identifier = identifier
        let retry = retry
        controller.edgeView = { edge, end in
            AnyView(PagedListEdgeView(edge: edge, end: end, endLabel: end == .older ? endLabel : nil, identifier: identifier, retry: retry))
        }
        controller.edgeHasEndView = endLabel != nil
        controller.swipeActions = swipeActions
        controller.fullSwipe = fullSwipe
        controller.header = header
        controller.loadMore = loadMore
        controller.loadNewer = loadNewer ?? {}
        controller.onReading = onReading
        controller.showNewest = showNewest
        controller.probe = probe
        controller.cachesHeights = cachesHeights
        controller.pinning = pinning ?? (direction == .up ? .ridesBottomEdge : .keepsRows)
        controller.animatesNewest = animatesNewest
        controller.prefetch = prefetch
        controller.cancelPrefetch = cancelPrefetch
        if controller.newest.beyondWindow != beyondWindow { controller.newest.beyondWindow = beyondWindow }
        controller.setRefresh(refresh)
        controller.update(items: items, edge: edge, newerEdge: newerEdge)
    }
}

/// A plain list: the collection view itself is the SwiftUI view.
struct PagedListRepresentable<Item: Identifiable & Equatable, Row: View>: UIViewRepresentable where Item.ID: Sendable {
    let config: PagedListConfig<Item, Row>

    func makeCoordinator() -> PagedListController<Item, Row> { config.makeController() }

    func makeUIView(context: Context) -> PagedListCollectionView { context.coordinator.collectionView }

    func updateUIView(_ view: PagedListCollectionView, context: Context) {
        config.apply(to: context.coordinator)
    }
}

/// A list with a bottom accessory or a newest-rows indicator: the host holds them with the rows.
struct PagedListHostRepresentable<Item: Identifiable & Equatable, Row: View>: UIViewControllerRepresentable where Item.ID: Sendable {
    let config: PagedListConfig<Item, Row>
    let overlay: AnyView?
    let accessory: AnyView?
    let accessoryBackground: AnyShapeStyle?
    let followsKeyboard: Bool
    let indicator: ((PagedListNewest) -> AnyView)?

    func makeCoordinator() -> PagedListController<Item, Row> { config.makeController() }

    func makeUIViewController(context: Context) -> PagedListHostController {
        PagedListHostController(list: context.coordinator.collectionView, newest: context.coordinator.newest)
    }

    func updateUIViewController(_ host: PagedListHostController, context: Context) {
        host.loadViewIfNeeded()
        host.setAccessory(accessory, background: accessoryBackground, followsKeyboard: followsKeyboard)
        host.setIndicator(indicator, direction: config.direction)
        host.setOverlay(overlay)
        config.apply(to: context.coordinator)
    }
}
#endif
