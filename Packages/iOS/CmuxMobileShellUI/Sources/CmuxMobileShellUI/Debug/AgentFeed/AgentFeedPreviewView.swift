#if DEBUG && os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Deterministic production-view fixture for Agent Feed UI and interaction tests.
public struct AgentFeedPreviewView: View {
    @Environment(\.agentFeedLocalizer) private var localizer
    private let scenario: AgentFeedPreviewScenario
    private let hostEventCount: Int
    @State private var selectedTab: MobilePrimaryTab = .notifications
    @State private var searchCoordinator = MobilePrimarySearchCoordinator(initialScope: .notifications)
    @State private var filter: MobileAgentFeedFilter
    @State private var items: [MobileAgentFeedItem]
    @State private var status: MobileAgentFeedStatus
    @State private var drafts: [MobileAgentFeedItemID: String] = [:]
    @State private var mutationStates: [MobileAgentFeedItemID: MobileAgentFeedMutationState] = [:]
    @State private var openedItem: MobileAgentFeedItem?
    @State private var performanceProbe = AgentFeedPerformanceProbe()

    public init() {
        let configuration = AgentFeedPreviewConfiguration.current()
        scenario = configuration.scenario
        hostEventCount = configuration.hostEventCount
        _filter = State(initialValue: configuration.filter)
        _items = State(initialValue: configuration.items)
        _status = State(initialValue: configuration.status)
    }

    public var body: some View {
        MobilePrimaryTabScaffold(
            selection: $selectedTab,
            searchCoordinator: searchCoordinator,
            notificationUnreadCount: items.lazy.filter(\.isActionable).count
        ) {
            Text(localizer.string("mobile.agentFeed.fixture.title", defaultValue: "Agent Feed fixture"))
        } notifications: {
            NavigationStack {
                scenarioFeed
                    .navigationDestination(isPresented: Binding(
                        get: { openedItem != nil },
                        set: { if !$0 { openedItem = nil } }
                    )) {
                        VStack(spacing: 12) {
                            Image(systemName: "terminal")
                            Text(openedItem?.wire.workstreamID ?? "")
                            Text(openedItem?.wire.workspaceID ?? "")
                            Text(openedItem?.wire.surfaceID ?? "")
                        }
                        .navigationTitle(localizer.string("mobile.agentFeed.fixture.agent", defaultValue: "Agent"))
                        .accessibilityIdentifier("MobileAgentFeedPreviewAgentDestination")
                    }
            }
        } workspaceSearch: {
            Text(localizer.string("mobile.agentFeed.fixture.title", defaultValue: "Agent Feed fixture"))
        } notificationSearch: {
            scenarioFeed
        }
        .dynamicTypeSize(scenario == .accessibility ? .accessibility3 : .large)
        .accessibilityIdentifier("AgentFeedScenarioScreen-\(scenario.rawValue)")
    }

    private var scenarioFeed: some View {
        VStack(spacing: 0) {
            scenarioMarker
            feed
            fixtureControls
            if scenario == .newActivity {
                Color.clear
                    .frame(height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("AgentFeedPerformanceMetrics")
                    .accessibilityValue(performanceProbe.markerValue)
            }
        }
    }

    private var scenarioMarker: some View {
        Color.clear
            .frame(height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("AgentFeedScenario-\(scenario.rawValue)")
            .accessibilityValue(Text(verbatim: "\(hostEventCount)/\(items.count)"))
    }

    @ViewBuilder
    private var fixtureControls: some View {
        switch scenario {
        case .empty:
            Button("Complete first load") { status = .ready }
                .accessibilityIdentifier("AgentFeedFixtureCompleteFirstLoad")
        case .newActivity:
            Button("Inject 100-event burst") {
                performanceProbe.start(
                    burst: AgentFeedPreviewConfiguration.injectedActivityBurst()
                ) { item in
                    items.insert(item, at: 0)
                }
            }
            .accessibilityIdentifier("AgentFeedFixtureInjectNewActivity")
        case .stress:
            if canLoadStressHistory {
                Button(
                    localizer.string(
                        "mobile.agentFeed.history.loadOlder",
                        defaultValue: "Load Older"
                    ),
                    action: loadOlder
                )
                .accessibilityIdentifier("AgentFeedFixtureLoadOlder")
            }
        case .reply:
            if mutationStates.values.contains(.sending) {
                Button("Acknowledge reply") {
                    drafts.removeAll()
                    mutationStates.removeAll()
                }
                .accessibilityIdentifier("AgentFeedFixtureAcknowledgeReply")
            }
        case .reconnect:
            Button("Finish reconciliation") {
                items = AgentFeedPreviewConfiguration.reconciledItems()
                status = .ready
            }
            .accessibilityIdentifier("AgentFeedFixtureFinishReconciliation")
        default:
            EmptyView()
        }
    }

    private var feed: some View {
        AgentFeedView(
            items: items,
            status: status,
            filter: $filter,
            drafts: drafts,
            mutationStates: mutationStates,
            hasMoreItems: (scenario == .stress && items.count < AgentFeedPreviewConfiguration.stressRetainedItemLimit)
                || scenario == .offline,
            canLoadOlder: canLoadStressHistory,
            isLoadingOlder: false,
            actions: AgentFeedActions(
                setDraft: { id, value in drafts[id] = value },
                reply: { item in mutationStates[item.id] = .sending },
                decide: { item, action in resolve(item, action: action) },
                open: { item in openedItem = item },
                refresh: { status = .loading },
                loadOlder: loadOlder,
                recordTopRowAppearance: performanceProbe.recordTopRowAppearance
            )
        )
    }

    private func loadOlder() {
        guard canLoadStressHistory else { return }
        let allItems = AgentFeedPreviewConfiguration.stressItems
        let end = min(
            items.count + 300,
            AgentFeedPreviewConfiguration.stressRetainedItemLimit,
            allItems.count
        )
        items = Array(allItems.prefix(end))
    }

    private var canLoadStressHistory: Bool {
        scenario == .stress
            && status == .ready
            && items.count < AgentFeedPreviewConfiguration.stressRetainedItemLimit
    }

    private func resolve(_ item: MobileAgentFeedItem, action: MobileAgentFeedAction) {
        let decision: MobileWorkstreamDecision
        switch action {
        case .permission(let mode): decision = .permission(mode: mode)
        case .exitPlan(let mode, let feedback): decision = .exitPlan(mode: mode, feedback: feedback)
        case .question(let selections): decision = .question(selections: selections)
        }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let wire = item.wire
        items[index] = MobileAgentFeedItem(
            macDeviceID: item.macDeviceID,
            macInstanceTag: item.macInstanceTag,
            macDisplayName: item.macDisplayName,
            connectionStatus: item.connectionStatus,
            wire: MobileWorkstreamFeedListItem(
                id: wire.id,
                workstreamID: wire.workstreamID,
                source: wire.source,
                kind: wire.kind,
                createdAt: wire.createdAt,
                updatedAt: Date(),
                cwd: wire.cwd,
                title: wire.title,
                workspaceID: wire.workspaceID,
                surfaceID: wire.surfaceID,
                status: .resolved(decision: decision),
                payload: wire.payload
            )
        )
        mutationStates[item.id] = .idle
    }
}
#endif
