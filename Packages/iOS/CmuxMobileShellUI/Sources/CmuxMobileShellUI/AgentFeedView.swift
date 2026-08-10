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
}

struct AgentFeedView: View {
    let items: [MobileAgentFeedItem]
    let status: MobileAgentFeedStatus
    @Binding var filter: MobileAgentFeedFilter
    let drafts: [MobileAgentFeedItemID: String]
    let mutationStates: [MobileAgentFeedItemID: MobileAgentFeedMutationState]
    let actions: AgentFeedActions
    @State private var expandedIDs: Set<MobileAgentFeedItemID> = []
    @State private var planFeedback: [MobileAgentFeedItemID: String] = [:]
    @State private var questionSelections: [MobileAgentFeedItemID: [String: Set<String>]] = [:]
    @State private var otherAnswers: [MobileAgentFeedItemID: [String: String]] = [:]
    @State private var knownItemIDs: Set<MobileAgentFeedItemID> = []
    @State private var unseenItemCount = 0
    @State private var newestItemIsVisible = true

    private var visibleItems: [MobileAgentFeedItem] { filter.apply(to: items) }

    var body: some View {
        VStack(spacing: 0) {
            AgentFeedStatusBanner(status: status, retry: actions.refresh)
            Picker(
                L10n.string("mobile.agentFeed.filter.label", defaultValue: "Feed filter"),
                selection: $filter
            ) {
                Text(L10n.string("mobile.agentFeed.filter.needsInput", defaultValue: "Needs Input"))
                    .tag(MobileAgentFeedFilter.needsInput)
                Text(L10n.string("mobile.agentFeed.filter.all", defaultValue: "All Activity"))
                    .tag(MobileAgentFeedFilter.allActivity)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("MobileAgentFeedFilter")

            if visibleItems.isEmpty {
                ContentUnavailableView(
                    L10n.string("mobile.agentFeed.empty.title", defaultValue: "No agent activity"),
                    systemImage: "text.bubble",
                    description: Text(L10n.string(
                        "mobile.agentFeed.empty.message",
                        defaultValue: "Agent updates and requests will appear here."
                    ))
                )
                .accessibilityIdentifier("MobileAgentFeedEmpty")
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        if unseenItemCount > 0 {
                            Button {
                                if let newest = visibleItems.first {
                                    withAnimation { proxy.scrollTo(newest.id, anchor: .top) }
                                }
                                unseenItemCount = 0
                            } label: {
                                Label(
                                    String(
                                        format: L10n.string(
                                            "mobile.agentFeed.newActivity.count",
                                            defaultValue: "%d new activities"
                                        ),
                                        unseenItemCount
                                    ),
                                    systemImage: "arrow.up"
                                )
                            }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("MobileAgentFeedNewActivity")
                        }
                        List(visibleItems) { item in
                            AgentFeedRow(
                                item: item,
                                isExpanded: expandedIDs.contains(item.id),
                                draft: drafts[item.id] ?? "",
                                mutationState: mutationStates[item.id] ?? .idle,
                                planFeedback: planFeedback[item.id] ?? "",
                                questionSelections: questionSelections[item.id] ?? [:],
                                otherAnswers: otherAnswers[item.id] ?? [:],
                                actions: AgentFeedRowActions(
                                    toggleExpanded: { toggleExpanded(item.id) },
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
                            .onAppear {
                                guard item.id == visibleItems.first?.id else { return }
                                newestItemIsVisible = true
                                unseenItemCount = 0
                            }
                            .onDisappear {
                                guard item.id == visibleItems.first?.id else { return }
                                newestItemIsVisible = false
                            }
                        }
                        .listStyle(.plain)
                        .refreshable { actions.refresh() }
                        .accessibilityIdentifier("MobileAgentFeedList")
                    }
                }
            }
        }
        .navigationTitle(L10n.string("mobile.tabs.feed", defaultValue: "Feed"))
        .accessibilityIdentifier("MobileAgentFeed")
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            let current = Set(ids)
            if !knownItemIDs.isEmpty, !newestItemIsVisible {
                unseenItemCount += current.subtracting(knownItemIDs).count
            }
            knownItemIDs = current
        }
    }

    private func toggleExpanded(_ id: MobileAgentFeedItemID) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }
}

private struct AgentFeedStatusBanner: View {
    let status: MobileAgentFeedStatus
    let retry: @MainActor () -> Void

    var body: some View {
        switch status {
        case .idle, .ready: EmptyView()
        case .loading:
            Label(L10n.string("mobile.agentFeed.status.syncing", defaultValue: "Syncing Feed…"), systemImage: "arrow.triangle.2.circlepath")
                .accessibilityIdentifier("MobileAgentFeedStatusSyncing")
        case .offlineCached:
            Label(L10n.string("mobile.agentFeed.status.offline", defaultValue: "Offline. Showing cached activity."), systemImage: "wifi.slash")
                .accessibilityIdentifier("MobileAgentFeedStatusOffline")
        case .partial:
            Label(L10n.string("mobile.agentFeed.status.partial", defaultValue: "Some computers are unavailable."), systemImage: "exclamationmark.triangle")
                .accessibilityIdentifier("MobileAgentFeedStatusPartial")
        case .reconnecting:
            Label(L10n.string("mobile.agentFeed.status.reconnecting", defaultValue: "Reconnecting…"), systemImage: "network")
                .accessibilityIdentifier("MobileAgentFeedStatusReconnecting")
        case .requiresMacUpdate:
            Label(L10n.string("mobile.agentFeed.status.updateMac", defaultValue: "Update cmux on your Mac to use Feed."), systemImage: "arrow.down.app")
                .accessibilityIdentifier("MobileAgentFeedStatusUpdateMac")
        case .unavailable, .failed:
            Button(action: retry) {
                Label(L10n.string("mobile.agentFeed.status.retry", defaultValue: "Feed unavailable. Retry"), systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("MobileAgentFeedRetry")
        }
    }
}
#endif
