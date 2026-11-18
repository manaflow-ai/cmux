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
/// two actions).
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
    var endLabel: LocalizedStringKey?
    var loadingLabel: LocalizedStringKey = "Loading…"
    var failureTitle: LocalizedStringKey = "Couldn't load"
    var identifier = "pagedList"
    var probe: PagedListProbe?
    var cachesHeights = true
    var refresh: (@MainActor () async -> Void)?

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
        switch phase {
        case .loading where items.isEmpty:
            CmuxSpinner(label: Text(loadingLabel))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(identifier).loading")
        case .failed(let message) where items.isEmpty:
            // The read replaces this state at once (a spinner), which would cancel a task owned by
            // the button: the retry runs unowned.
            EmptyState(symbol: "exclamationmark.triangle", title: failureTitle, message: "\(message)",
                       retry: { [retry] in Task { await retry() } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("\(identifier).failed")
        default:
            if items.isEmpty, edge == .end {
                empty()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(identifier).empty")
            } else {
                PagedListRepresentable(direction: direction, items: items, edge: edge, loadMore: loadMore, retry: retry,
                                       row: row, swipeActions: swipeActions, endLabel: endLabel, identifier: identifier,
                                       probe: probe, cachesHeights: cachesHeights, refresh: refresh)
            }
        }
    }

    /// Trailing swipe actions per row (UIKit's swipe; the first is the full swipe's).
    public func pagedSwipeActions(_ actions: @escaping (Item) -> [PagedListAction]) -> Self {
        var copy = self
        copy.swipeActions = actions
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
    }
}

/// The edge's row: a spinner while more pages exist (the reader rarely reaches it: the page is read
/// two screens ahead), Try Again after a failure, and the end label. One height for the spinner and
/// the end, so the edge changing state moves nothing.
struct PagedListEdgeView: View {
    let edge: PagedListEdge
    let endLabel: LocalizedStringKey?
    let identifier: String
    let retry: @MainActor () async -> Void

    var body: some View {
        Group {
            switch edge {
            case .more, .loading:
                CmuxSpinner()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Loading more"))
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
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 52)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier).edge.\(stateName)")
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

struct PagedListRepresentable<Item: Identifiable & Equatable, Row: View>: UIViewRepresentable where Item.ID: Sendable {
    let direction: PagedListDirection
    let items: [Item]
    let edge: PagedListEdge
    let loadMore: @MainActor () -> Void
    let retry: @MainActor () async -> Void
    let row: (Item) -> Row
    let swipeActions: ((Item) -> [PagedListAction])?
    let endLabel: LocalizedStringKey?
    let identifier: String
    let probe: PagedListProbe?
    let cachesHeights: Bool
    let refresh: (@MainActor () async -> Void)?

    func makeCoordinator() -> PagedListController<Item, Row> {
        PagedListController(direction: direction, row: row, edgeView: { _ in AnyView(EmptyView()) })
    }

    func makeUIView(context: Context) -> PagedListCollectionView {
        let view = context.coordinator.collectionView
        view.accessibilityIdentifier = identifier
        return view
    }

    func updateUIView(_ view: PagedListCollectionView, context: Context) {
        let controller = context.coordinator
        controller.row = row
        let endLabel = endLabel
        let identifier = identifier
        let retry = retry
        controller.edgeView = { edge in AnyView(PagedListEdgeView(edge: edge, endLabel: endLabel, identifier: identifier, retry: retry)) }
        controller.edgeHasEndView = endLabel != nil
        controller.swipeActions = swipeActions
        controller.loadMore = loadMore
        controller.probe = probe
        controller.cachesHeights = cachesHeights
        controller.setRefresh(refresh)
        controller.update(items: items, edge: edge)
    }
}
#endif
