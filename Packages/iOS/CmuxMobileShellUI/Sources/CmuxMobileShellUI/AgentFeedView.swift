#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The Feed tab's visible filter: everything, or only rows awaiting input.
enum AgentFeedFilter: Hashable, Sendable {
    case all
    case needsInput
}

struct AgentFeedItemsRevision: Equatable, Sendable {
    let sourceRevision: UInt64
    let scopeRevision: AgentFeedScopeRevision?

    init(
        sourceRevision: UInt64,
        scopeRevision: AgentFeedScopeRevision? = nil
    ) {
        self.sourceRevision = sourceRevision
        self.scopeRevision = scopeRevision
    }
}

/// The store-free Feed presentation: an X-style full-width timeline of agent
/// activity with inline output and inline decision controls. Distinct from
/// the Notifications tab, which stays a read/unread notification list.
struct AgentFeedView: View {
    let performanceObserver: (any MobileFeedPerformanceObserving)?
    let items: [MobileAgentFeedItem]
    let itemsRevision: AgentFeedItemsRevision
    let status: MobileNotificationFeedStatus
    let pendingReplyRequestIDs: Set<String>
    let pendingTerminalReplyItemIDs: Set<MobileAgentFeedItemID>
    var failedTerminalReplies: [MobileAgentFeedItemID: MobileAgentFeedFailedReply] = [:]
    let refreshesOnAppear: Bool
    var isActive = true
    let actions: AgentFeedActions
    var searchText: String = ""
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @State private var projection: AgentFeedProjection
    @State private var now = Date()
    @State private var composeContext: AgentFeedComposeContext?
    @State private var readingItem: MobileAgentFeedItem?

    init(
        items: [MobileAgentFeedItem],
        itemsRevision: AgentFeedItemsRevision = AgentFeedItemsRevision(sourceRevision: 0),
        status: MobileNotificationFeedStatus,
        pendingReplyRequestIDs: Set<String>,
        pendingTerminalReplyItemIDs: Set<MobileAgentFeedItemID>,
        failedTerminalReplies: [MobileAgentFeedItemID: MobileAgentFeedFailedReply] = [:],
        refreshesOnAppear: Bool,
        isActive: Bool = true,
        actions: AgentFeedActions,
        searchText: String = "",
        performanceObserver: (any MobileFeedPerformanceObserving)? = nil
    ) {
        self.performanceObserver = performanceObserver
        self.items = items
        self.itemsRevision = itemsRevision
        self.status = status
        self.pendingReplyRequestIDs = pendingReplyRequestIDs
        self.pendingTerminalReplyItemIDs = pendingTerminalReplyItemIDs
        self.failedTerminalReplies = failedTerminalReplies
        self.refreshesOnAppear = refreshesOnAppear
        self.isActive = isActive
        self.actions = actions
        self.searchText = searchText
        _projection = State(initialValue: AgentFeedProjection(
            items: items,
            itemsRevision: itemsRevision,
            searchText: searchText,
            performanceObserver: performanceObserver
        ))
    }

    /// Row actions with the composer hook bound to this view's sheet state.
    private var rowActions: AgentFeedActions {
        var rowActions = actions
        rowActions.beginCompose = { item, kind in
            composeContext = AgentFeedComposeContext(item: item, kind: kind)
        }
        rowActions.retryTerminalReply = { item, text in
            composeContext = AgentFeedComposeContext(item: item, kind: .terminalReply, initialDraft: text)
        }
        rowActions.viewFullText = { readingItem = $0 }
        return rowActions
    }

    var body: some View {
        Group {
            switch status {
            case .idle, .loading where items.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable where items.isEmpty:
                AgentFeedUnavailableView(retry: { Task { await actions.refresh() } })
            case .requiresMacUpdate where items.isEmpty:
                AgentFeedRequiresMacUpdateView()
            default:
                feedList
            }
        }
        .overlay { MobileReplayPrivacyMask().allowsHitTesting(false) }
        // The shell supplies the shared computer and settings toolbar.
        .mobileInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AgentFeedFilterMenu(
                    filter: projection.filter,
                    needsInputCount: visibleNeedsInputCount,
                    setFilter: { newFilter in
                        projection.filter = newFilter
                        actions.filterChanged(newFilter)
                    }
                )
            }
        }
        .sheet(item: $composeContext) { context in
            AgentFeedReplyComposer(context: context, actions: actions)
                .overlay { MobileReplayPrivacyMask().allowsHitTesting(false) }
        }
        .sheet(item: $readingItem) { item in
            AgentFeedFullTextView(item: item, load: actions.loadFullText)
                .overlay { MobileReplayPrivacyMask().allowsHitTesting(false) }
        }
        .onAppear {
            now = Date()
        }
        .task(id: isActive) {
            guard isActive, refreshesOnAppear else { return }
            // Relative timestamps are anchored to the last visible visit, so
            // switching away and back cannot leave the feed comparing rows to
            // the date from its first appearance.
            now = Date()
            await actions.refresh()
        }
        .onChange(of: itemsRevision) { oldRevision, newRevision in
            if oldRevision.scopeRevision != newRevision.scopeRevision {
                composeContext = nil
                readingItem = nil
            }
            projection.update(items: items, itemsRevision: itemsRevision)
        }
        .onChange(of: searchText) { _, newSearchText in
            projection.searchText = newSearchText
        }
    }

    private var visibleRows: [AgentFeedRowModel] {
        projection.rows(for: itemsRevision)
    }

    private var visibleNeedsInputCount: Int {
        projection.needsInputCount(for: itemsRevision)
    }

    private var feedList: some View {
        List {
            if !items.isEmpty, status == .unavailable || status == .requiresMacUpdate {
                Section {
                    AgentFeedAvailabilityBanner(status: status)
                }
            }
            Section {
                if visibleRows.isEmpty {
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .listRowSeparator(.hidden)
                    } else {
                        AgentFeedEmptyView(filter: projection.filter)
                            .listRowSeparator(.hidden)
                    }
                } else {
                    ForEach(visibleRows) { model in
                        let item = model.item
                        AgentFeedRow(
                            model: model,
                            isReplyPending: pendingTerminalReplyItemIDs.contains(item.id)
                                || item.requestID.map { pendingReplyRequestIDs.contains($0) } ?? false,
                            now: now,
                            bubbleQuotes: displaySettings.feedBubbleQuotes,
                            showsTab: displaySettings.feedShowsTab,
                            failedReply: failedTerminalReplies[item.id],
                            actions: rowActions
                        )
                        .equatable()
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        // X-style: hairlines run BETWEEN posts only — no
                        // divider above the first row.
                        .listRowSeparator(.hidden, edges: .top)
                        .listRowSeparator(.visible, edges: .bottom)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        // Needs-input triage in the mark-read swipe style.
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if item.effectiveNeedsInput {
                                Button {
                                    actions.setNeedsInput(item, false)
                                } label: {
                                    Label(
                                        String(
                                            localized: "mobile.agentFeed.triage.done",
                                            defaultValue: "Done",
                                            bundle: .module
                                        ),
                                        systemImage: "checkmark.circle.fill"
                                    )
                                }
                                .tint(.accentColor)
                            } else {
                                Button {
                                    actions.setNeedsInput(item, true)
                                } label: {
                                    Label(
                                        String(
                                            localized: "mobile.agentFeed.triage.needsInput",
                                            defaultValue: "Needs Input",
                                            bundle: .module
                                        ),
                                        systemImage: "exclamationmark.circle.fill"
                                    )
                                }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
        }
        .modifier(AgentFeedPerformanceModifier(
            observer: performanceObserver, isActive: isActive, itemCount: items.count
        ))
        .listStyle(.plain)
        .accessibilityIdentifier("AgentFeedScrollContainer")
        // Swiping the feed lowers the keyboard, so an abandoned inline reply
        // never pins it over the timeline.
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            now = Date()
            await actions.refresh()
        }
    }

}

/// The Feed's filter as a toolbar menu, mirroring the Workspaces filter
/// control: a `Menu` hosting a picker, with the filled Mail-style icon while
/// a narrowing filter is active.
private struct AgentFeedFilterMenu: View {
    let filter: AgentFeedFilter
    let needsInputCount: Int
    let setFilter: (AgentFeedFilter) -> Void

    var body: some View {
        Menu {
            Picker(
                String(
                    localized: "mobile.agentFeed.filter",
                    defaultValue: "Filter",
                    bundle: .module
                ),
                selection: Binding(get: { filter }, set: { setFilter($0) })
            ) {
                Text(String(
                    localized: "mobile.agentFeed.filter.all",
                    defaultValue: "All Activity",
                    bundle: .module
                ))
                .tag(AgentFeedFilter.all)
                Text(
                    needsInputCount > 0
                        ? String(
                            localized: "mobile.agentFeed.filter.needsInputCount",
                            defaultValue: "Needs Input (\(needsInputCount))",
                            bundle: .module
                        )
                        : String(
                            localized: "mobile.agentFeed.filter.needsInput",
                            defaultValue: "Needs Input",
                            bundle: .module
                        )
                )
                .tag(AgentFeedFilter.needsInput)
            }
        } label: {
            Image(systemName: filter == .needsInput
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(String(
            localized: "mobile.agentFeed.filter",
            defaultValue: "Filter",
            bundle: .module
        ))
        .accessibilityIdentifier("MobileAgentFeedFilterMenu")
    }
}

private struct AgentFeedEmptyView: View {
    let filter: AgentFeedFilter

    var body: some View {
        ContentUnavailableView(
            filter == .needsInput
                ? String(
                    localized: "mobile.agentFeed.empty.needsInput.title",
                    defaultValue: "Nothing Needs You",
                    bundle: .module
                )
                : String(
                    localized: "mobile.agentFeed.empty.all.title",
                    defaultValue: "No Agent Activity Yet",
                    bundle: .module
                ),
            systemImage: filter == .needsInput ? "checkmark.circle" : "waveform",
            description: Text(
                filter == .needsInput
                    ? String(
                        localized: "mobile.agentFeed.empty.needsInput.description",
                        defaultValue: "Agent questions, permission requests, and plan approvals will appear here the moment they need you.",
                        bundle: .module
                    )
                    : String(
                        localized: "mobile.agentFeed.empty.all.description",
                        defaultValue: "Run a coding agent in cmux on your Mac and its activity streams here.",
                        bundle: .module
                    )
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

private struct AgentFeedUnavailableView: View {
    let retry: @MainActor () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                String(
                    localized: "mobile.agentFeed.unavailable.title",
                    defaultValue: "Feed Unavailable",
                    bundle: .module
                ),
                systemImage: "wifi.slash"
            )
        } description: {
            Text(String(
                localized: "mobile.agentFeed.unavailable.description",
                defaultValue: "Connect to a Mac to see its agent activity.",
                bundle: .module
            ))
        } actions: {
            Button(String(
                localized: "mobile.agentFeed.retry",
                defaultValue: "Try Again",
                bundle: .module
            ), action: retry)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("MobileAgentFeedRetry")
        }
        .accessibilityIdentifier("MobileAgentFeedUnavailable")
    }
}

/// Shown above cached rows when the Feed cannot refresh, so stale activity is
/// never mistaken for live activity.
private struct AgentFeedAvailabilityBanner: View {
    let status: MobileNotificationFeedStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .requiresMacUpdate ? "arrow.down.circle" : "wifi.slash")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileAgentFeedAvailabilityBanner")
    }

    private var title: String {
        status == .requiresMacUpdate
            ? String(localized: "mobile.agentFeed.update.title",
                     defaultValue: "Update cmux on your Mac", bundle: .module)
            : String(localized: "mobile.agentFeed.offline.title",
                     defaultValue: "Feed is offline", bundle: .module)
    }

    private var detail: String {
        status == .requiresMacUpdate
            ? String(localized: "mobile.agentFeed.update.inlineBody",
                     defaultValue: "Some paired Macs can’t stream agent activity yet.", bundle: .module)
            : String(localized: "mobile.agentFeed.offline.inlineBody",
                     defaultValue: "Showing the latest activity synced from your Macs.", bundle: .module)
    }
}

private struct AgentFeedRequiresMacUpdateView: View {
    var body: some View {
        ContentUnavailableView(
            String(
                localized: "mobile.agentFeed.requiresUpdate.title",
                defaultValue: "Update cmux on Your Mac",
                bundle: .module
            ),
            systemImage: "arrow.triangle.2.circlepath",
            description: Text(String(
                localized: "mobile.agentFeed.requiresUpdate.description",
                defaultValue: "The connected Mac's cmux predates the agent Feed. Update it to stream agent activity here.",
                bundle: .module
            ))
        )
    }
}
#endif
