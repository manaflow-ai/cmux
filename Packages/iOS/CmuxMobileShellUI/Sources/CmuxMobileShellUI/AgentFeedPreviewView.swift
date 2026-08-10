#if DEBUG && os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Deterministic production-view fixture for Agent Feed UI and interaction tests.
public struct AgentFeedPreviewView: View {
    @State private var selectedTab: MobilePrimaryTab = .notifications
    @State private var searchCoordinator = MobilePrimarySearchCoordinator(initialScope: .notifications)
    @State private var filter: MobileAgentFeedFilter = .needsInput
    @State private var items = AgentFeedPreviewFixture.items
    @State private var drafts: [MobileAgentFeedItemID: String] = [:]
    @State private var mutationStates: [MobileAgentFeedItemID: MobileAgentFeedMutationState] = [:]
    @State private var openedItem: MobileAgentFeedItem?

    public init() {}

    public var body: some View {
        MobilePrimaryTabScaffold(
            selection: $selectedTab,
            searchCoordinator: searchCoordinator,
            notificationUnreadCount: items.lazy.filter(\.isActionable).count
        ) {
            Text(L10n.string("mobile.agentFeed.fixture.title", defaultValue: "Agent Feed fixture"))
        } notifications: {
            NavigationStack {
                feed
                    .navigationDestination(isPresented: Binding(
                        get: { openedItem != nil },
                        set: { if !$0 { openedItem = nil } }
                    )) {
                        VStack(spacing: 12) {
                            Image(systemName: "terminal")
                            Text(openedItem?.wire.workstreamID ?? "")
                        }
                        .navigationTitle(L10n.string("mobile.agentFeed.fixture.agent", defaultValue: "Agent"))
                        .accessibilityIdentifier("MobileAgentFeedPreviewAgentDestination")
                    }
            }
        } workspaceSearch: {
            Text(L10n.string("mobile.agentFeed.fixture.title", defaultValue: "Agent Feed fixture"))
        } notificationSearch: {
            feed
        }
    }

    private var feed: some View {
        AgentFeedView(
            items: items,
            status: .ready,
            filter: $filter,
            drafts: drafts,
            mutationStates: mutationStates,
            actions: AgentFeedActions(
                setDraft: { id, value in drafts[id] = value },
                reply: { item in
                    drafts[item.id] = nil
                    mutationStates[item.id] = .idle
                },
                decide: { item, action in resolve(item, action: action) },
                open: { item in openedItem = item },
                refresh: {}
            )
        )
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

private struct AgentFeedPreviewFixture {
    static let items: [MobileAgentFeedItem] = [
        item(
            id: "00000000-0000-0000-0000-000000000101",
            source: "codex",
            kind: "permissionRequest",
            minutesAgo: 1,
            title: "Codex needs permission",
            payload: .permission(
                requestID: "permission-101",
                toolName: "Bash",
                safeInput: "command: …, timeout: …",
                supportedModes: ["once", "always", "deny"]
            )
        ),
        item(
            id: "00000000-0000-0000-0000-000000000102",
            source: "claude",
            kind: "exitPlan",
            minutesAgo: 2,
            title: "Claude finished a plan",
            payload: .exitPlan(
                requestID: "plan-102",
                plan: "1. Add an authenticated feed RPC.\n2. Aggregate immutable events across Macs.\n3. Route every response to its exact surface.",
                summary: "Review the iOS Agent Feed plan",
                defaultMode: "manual"
            )
        ),
        item(
            id: "00000000-0000-0000-0000-000000000103",
            source: "gemini",
            kind: "question",
            minutesAgo: 3,
            title: "Gemini has two questions",
            payload: .question(requestID: "question-103", questions: [
                MobileWorkstreamQuestion(
                    id: "scope",
                    header: "Scope",
                    prompt: "Which clients should receive the feed?",
                    multiSelect: true,
                    options: [
                        .init(id: "iphone", label: "iPhone", description: "The signed iOS client"),
                        .init(id: "ipad", label: "iPad", description: "The tablet layout"),
                    ]
                ),
                MobileWorkstreamQuestion(
                    id: "priority",
                    header: "Priority",
                    prompt: "Which request should appear first?",
                    multiSelect: false,
                    options: [
                        .init(id: "blocking", label: "Blocking requests"),
                        .init(id: "recent", label: "Most recent activity"),
                    ]
                ),
            ])
        ),
        item(
            id: "00000000-0000-0000-0000-000000000104",
            source: "opencode",
            kind: "toolResult",
            minutesAgo: 4,
            title: "OpenCode command failed",
            status: .telemetry,
            payload: .toolResult(name: "swift test", result: "Exited with status 1", isError: true)
        ),
        item(
            id: "00000000-0000-0000-0000-000000000105",
            source: "hermes-agent",
            kind: "stop",
            minutesAgo: 5,
            title: "Hermes finished a turn",
            status: .telemetry,
            payload: .stop(reason: "Implementation is ready for a reply.")
        ),
    ]

    private static func item(
        id: String,
        source: String,
        kind: String,
        minutesAgo: TimeInterval,
        title: String,
        status: MobileWorkstreamFeedStatus = .pending,
        payload: MobileWorkstreamFeedPayload
    ) -> MobileAgentFeedItem {
        let date = Date().addingTimeInterval(-minutesAgo * 60)
        return MobileAgentFeedItem(
            macDeviceID: source == "claude" ? "mac-studio" : "macbook",
            macInstanceTag: "fixture",
            macDisplayName: source == "claude" ? "Studio" : "MacBook Pro",
            connectionStatus: .connected,
            wire: MobileWorkstreamFeedListItem(
                id: UUID(uuidString: id)!,
                workstreamID: "\(source)-fixture-session",
                source: source,
                kind: kind,
                createdAt: date,
                updatedAt: date,
                cwd: "/cmux/worktrees/agent-feed",
                title: title,
                workspaceID: "workspace-agent-feed",
                surfaceID: "surface-agent-feed",
                status: status,
                payload: payload
            )
        )
    }
}
#endif
