#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct AgentFeedActions {
    let setDraft: @MainActor (MobileAgentFeedItemID, String) -> Void
    let reply: @MainActor (MobileAgentFeedItem) -> Void
    let decide: @MainActor (MobileAgentFeedItem, MobileAgentFeedAction) -> Void
    let open: @MainActor (MobileAgentFeedItem) -> Void
    let refresh: @MainActor () -> Void
    let loadOlder: @MainActor () -> Void
    let recordTopRowAppearance: @MainActor (MobileAgentFeedItemID) -> Void
}

struct AgentFeedView: View {
    let items: [MobileAgentFeedItem]
    let status: MobileAgentFeedStatus
    @Binding var filter: MobileAgentFeedFilter
    let drafts: [MobileAgentFeedItemID: String]
    let mutationStates: [MobileAgentFeedItemID: MobileAgentFeedMutationState]
    let hasMoreItems: Bool
    let canLoadOlder: Bool
    let isLoadingOlder: Bool
    let actions: AgentFeedActions
    @State private var expandedIDs: Set<MobileAgentFeedItemID> = []
    @State private var planFeedback: [MobileAgentFeedItemID: String] = [:]
    @State private var questionSelections: [MobileAgentFeedItemID: [String: Set<String>]] = [:]
    @State private var otherAnswers: [MobileAgentFeedItemID: [String: String]] = [:]
    @State private var knownItemIDs: Set<MobileAgentFeedItemID> = []
    @State private var visibilityTracker = AgentFeedVisibilityTracker()
    @State private var unseenItemCount = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.agentFeedLocalizer) private var localizer

    var body: some View {
        let visibleItems = filter.apply(to: items)
        VStack(spacing: 0) {
            AgentFeedStatusBanner(status: status, retry: actions.refresh, localizer: localizer)
            filterControl
            .padding(.horizontal)
            .padding(.vertical, 8)

            if visibleItems.isEmpty {
                ContentUnavailableView(
                    localizer.string("mobile.agentFeed.empty.title", defaultValue: "No agent activity"),
                    systemImage: "text.bubble",
                    description: Text(localizer.string(
                        "mobile.agentFeed.empty.message",
                        defaultValue: "Agent updates and requests will appear here."
                    ))
                )
                .accessibilityIdentifier("MobileAgentFeedEmpty")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleItems) { item in
                                AgentFeedRow(
                                    item: item,
                                    isExpanded: expandedIDs.contains(item.id),
                                    draft: drafts[item.id] ?? "",
                                    mutationState: mutationStates[item.id] ?? .idle,
                                    interactionsEnabled: interactionsEnabled(for: item),
                                    planFeedback: planFeedback[item.id] ?? "",
                                    questionSelections: questionSelections[item.id] ?? [:],
                                    otherAnswers: otherAnswers[item.id] ?? [:],
                                    actions: AgentFeedRowActions(
                                        setExpanded: { setExpanded($0, id: item.id) },
                                        setDraft: { actions.setDraft(item.id, $0) },
                                        setPlanFeedback: { planFeedback[item.id] = $0 },
                                        setQuestionSelection: { question, selection in
                                            questionSelections[item.id, default: [:]][question] = selection
                                        },
                                        setOtherAnswer: { question, value in
                                            otherAnswers[item.id, default: [:]][question] = value
                                        },
                                        reply: { actions.reply(item) },
                                        decide: { actions.decide(item, $0) },
                                        open: { actions.open(item) }
                                    )
                                )
                                .equatable()
                                .padding(.horizontal)
                                .id(item.id)
                                .onAppear {
                                    guard item.id == visibleItems.first?.id else { return }
                                    actions.recordTopRowAppearance(item.id)
                                }
                                Divider().padding(.leading)
                            }
                            if hasMoreItems {
                                loadOlderControl.padding(.horizontal)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .refreshable { actions.refresh() }
                    .accessibilityIdentifier("MobileAgentFeedList")
                    .onScrollTargetVisibilityChange(
                        idType: MobileAgentFeedItemID.self,
                        threshold: 0.01
                    ) { visibleIDs in
                        visibilityTracker.replaceVisibleIDs(visibleIDs)
                    }
                    .overlay(alignment: .top) {
                        if unseenItemCount > 0 {
                            Button {
                                if let newest = visibleItems.first {
                                    withAnimation { proxy.scrollTo(newest.id, anchor: .top) }
                                }
                                unseenItemCount = 0
                            } label: {
                                Label(
                                    localizer.string(
                                        "mobile.agentFeed.newActivity.count",
                                        defaultValue: "\(unseenItemCount) new activities"
                                    ),
                                    systemImage: "arrow.up"
                                )
                            }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("MobileAgentFeedNewActivity")
                            .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .onChange(of: visibleItems.map(\.id), initial: true) { oldIDs, newIDs in
                        let allCurrentIDs = Set(items.map(\.id))
                        let genuinelyNewIDs = allCurrentIDs.subtracting(knownItemIDs)
                        defer { knownItemIDs = allCurrentIDs }
                        guard !oldIDs.isEmpty,
                              !genuinelyNewIDs.isEmpty,
                              let oldNewestID = oldIDs.first,
                              !visibilityTracker.visibleIDs.contains(oldNewestID) else {
                            return
                        }
                        let insertedVisibleCount = Set(newIDs)
                            .subtracting(oldIDs)
                            .intersection(genuinelyNewIDs)
                            .count
                        guard insertedVisibleCount > 0 else { return }
                        let anchorID = visibilityTracker.topVisibleID(orderedBy: oldIDs)
                        unseenItemCount += insertedVisibleCount
                        guard let anchorID else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(anchorID, anchor: .top)
                        }
                    }
                }
            }
        }
        .navigationTitle(localizer.string("mobile.tabs.feed", defaultValue: "Feed"))
        .accessibilityIdentifier("MobileAgentFeed")
    }

    private var loadOlderControl: some View {
        Button(action: actions.loadOlder) {
            HStack {
                if isLoadingOlder { ProgressView() }
                Text(isLoadingOlder
                    ? localizer.string(
                        "mobile.agentFeed.history.loadingOlder",
                        defaultValue: "Loading older activity…"
                    )
                    : localizer.string(
                        "mobile.agentFeed.history.loadOlder",
                        defaultValue: "Load Older"
                    ))
                Spacer()
            }
            .frame(minHeight: 44)
        }
        .disabled(!canLoadOlder || isLoadingOlder)
        .accessibilityIdentifier("MobileAgentFeedLoadOlder")
    }

    private func setExpanded(_ isExpanded: Bool, id: MobileAgentFeedItemID) {
        if isExpanded {
            expandedIDs.insert(id)
        } else {
            expandedIDs.remove(id)
        }
    }

    private func interactionsEnabled(for item: MobileAgentFeedItem) -> Bool {
        guard item.connectionStatus == .connected else { return false }
        switch status {
        case .ready, .partial: return true
        case .idle, .loading, .offlineCached, .reconnecting, .unavailable, .requiresMacUpdate, .failed:
            return false
        }
    }

    @ViewBuilder
    private var filterControl: some View {
        if dynamicTypeSize.isAccessibilitySize {
            filterPicker
                .pickerStyle(.menu)
                .frame(minHeight: 44)
        } else {
            filterPicker
                .pickerStyle(.segmented)
        }
    }

    private var filterPicker: some View {
        Picker(
            localizer.string("mobile.agentFeed.filter.label", defaultValue: "Feed filter"),
            selection: $filter
        ) {
            Text(localizer.string("mobile.agentFeed.filter.needsInput", defaultValue: "Needs Input"))
                .tag(MobileAgentFeedFilter.needsInput)
            Text(localizer.string("mobile.agentFeed.filter.all", defaultValue: "All Activity"))
                .tag(MobileAgentFeedFilter.allActivity)
        }
        .accessibilityIdentifier("MobileAgentFeedFilter")
    }
}

/// Observes row visibility without publishing per-frame SwiftUI state. The
/// scroll view remains the sole owner of gesture physics; Feed reads this set
/// only when an item insertion must preserve an off-top viewport.
@MainActor
private final class AgentFeedVisibilityTracker {
    private(set) var visibleIDs: Set<MobileAgentFeedItemID> = []

    func replaceVisibleIDs(_ ids: [MobileAgentFeedItemID]) {
        visibleIDs = Set(ids)
    }

    func topVisibleID(orderedBy ids: [MobileAgentFeedItemID]) -> MobileAgentFeedItemID? {
        ids.first(where: visibleIDs.contains)
    }
}

private struct AgentFeedStatusBanner: View {
    let status: MobileAgentFeedStatus
    let retry: @MainActor () -> Void
    let localizer: AgentFeedLocalizer

    var body: some View {
        switch status {
        case .idle, .ready: EmptyView()
        case .loading:
            Label(localizer.string("mobile.agentFeed.status.syncing", defaultValue: "Syncing Feed…"), systemImage: "arrow.triangle.2.circlepath")
                .accessibilityIdentifier("MobileAgentFeedStatusSyncing")
        case .offlineCached:
            Label(localizer.string("mobile.agentFeed.status.offline", defaultValue: "Offline. Showing cached activity."), systemImage: "wifi.slash")
                .accessibilityIdentifier("MobileAgentFeedStatusOffline")
        case .partial:
            Label(localizer.string("mobile.agentFeed.status.partial", defaultValue: "Some computers are unavailable."), systemImage: "exclamationmark.triangle")
                .accessibilityIdentifier("MobileAgentFeedStatusPartial")
        case .reconnecting:
            Label(localizer.string("mobile.agentFeed.status.reconnecting", defaultValue: "Reconnecting…"), systemImage: "network")
                .accessibilityIdentifier("MobileAgentFeedStatusReconnecting")
        case .requiresMacUpdate:
            Label(localizer.string("mobile.agentFeed.status.updateMac", defaultValue: "Update cmux on your Mac to use Feed."), systemImage: "arrow.down.app")
                .accessibilityIdentifier("MobileAgentFeedStatusUpdateMac")
        case .unavailable, .failed:
            Button(action: retry) {
                Label(localizer.string("mobile.agentFeed.status.retry", defaultValue: "Feed unavailable. Retry"), systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("MobileAgentFeedRetry")
        }
    }
}
#endif
