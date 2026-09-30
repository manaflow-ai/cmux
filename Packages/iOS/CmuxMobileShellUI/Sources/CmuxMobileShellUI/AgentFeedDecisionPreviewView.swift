#if DEBUG && os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// Deterministic Feed fixture for the decision controls and long-list scroll
/// path. It uses the production Feed view so screenshots exercise row identity,
/// filtering, paging, Markdown rendering, and action layout together.
public struct AgentFeedDecisionPreviewView: View {
    @State private var selectedTab: MobilePrimaryTab = .feed
    @State private var searchCoordinator = MobilePrimarySearchCoordinator(initialScope: .feed)
    @State private var path: [String] = []
    @State private var result = ""
    @State private var items: [MobileAgentFeedItem]

    public init() {
        _items = State(initialValue: Self.makeItems(referenceDate: Date()))
    }

    public var body: some View {
        MobilePrimaryTabScaffold(
            selection: $selectedTab,
            searchCoordinator: searchCoordinator,
            notificationUnreadCount: 0
        ) {
            NavigationStack { Text(verbatim: "Workspaces").toolbar { rootToolbar } }
        } feed: {
            NavigationStack(path: $path) {
                AgentFeedView(
                    items: items,
                    status: .ready,
                    pendingReplyRequestIDs: [],
                    pendingTerminalReplyItemIDs: [],
                    refreshesOnAppear: false,
                    actions: actions,
                    searchText: searchCoordinator.searchDestinationText(for: .feed)
                )
                .toolbar { rootToolbar }
                .navigationDestination(for: String.self) { destination in
                    Text(verbatim: "Opened preview " + destination)
                }
            }
        } notifications: {
            NavigationStack { Text(verbatim: "Notifications").toolbar { rootToolbar } }
        } search: {
            MobilePrimarySearchNavigationStack(
                path: .constant([]),
                selection: $selectedTab,
                searchCoordinator: searchCoordinator
            ) {
                AgentFeedView(
                    items: items,
                    status: .ready,
                    pendingReplyRequestIDs: [],
                    pendingTerminalReplyItemIDs: [],
                    refreshesOnAppear: false,
                    actions: actions,
                    searchText: searchCoordinator.searchDestinationText(for: .feed)
                )
            } destination: { _ in EmptyView() }
        }
        .overlay(alignment: .bottom) {
            if !result.isEmpty {
                Text(result)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("MobileAgentFeedDecisionResult")
            }
        }
    }

    private var actions: AgentFeedActions {
        AgentFeedActions(
            permissionReply: { _, mode in result = "Permission reply: \(mode)" },
            questionReply: { _, _ in result = "Question reply accepted" },
            openDestination: { item in path = [item.remoteSurfaceID == nil ? "workspace" : "tab"] },
            viewFullText: { _ in result = "Full text opened" }
        )
    }

    private static func makeItems(referenceDate now: Date) -> [MobileAgentFeedItem] {
        let question = MobileAgentFeedItem(
            macDeviceID: "preview-mac",
            macDisplayName: "Preview Mac",
            itemID: "question-preview",
            workstreamID: "claude-question-preview",
            source: "claude",
            kind: .question,
            status: .pending,
            createdAt: now,
            updatedAt: now,
            requestID: "question-preview-request",
            questions: [
                MobileAgentFeedQuestion(
                    id: "deploy",
                    header: "Deploy target",
                    prompt: "Where should this deploy?",
                    options: [
                        MobileAgentFeedQuestionOption(
                            id: "production",
                            label: "Production",
                            description: "Deploy the current release to production."
                        ),
                        MobileAgentFeedQuestionOption(
                            id: "staging",
                            label: "Staging",
                            description: "Use the staging environment for review."
                        ),
                    ]
                ),
                MobileAgentFeedQuestion(
                    id: "events",
                    header: "Allow events",
                    prompt: "Which events should be enabled?",
                    multiSelect: true,
                    options: [
                        MobileAgentFeedQuestionOption(
                            id: "build",
                            label: "Build events",
                            description: "Allow build notifications."
                        ),
                        MobileAgentFeedQuestionOption(
                            id: "deploy",
                            label: "Deploy events",
                            description: "Allow deploy notifications."
                        ),
                        MobileAgentFeedQuestionOption(
                            id: "failure",
                            label: "Failure events",
                            description: "Allow failure notifications."
                        ),
                    ]
                ),
            ],
            context: MobileAgentFeedContext(lastUserMessage: "Deploy target and event settings"),
            connectionStatus: .connected
        )

        let permission = MobileAgentFeedItem(
            macDeviceID: "preview-mac",
            macDisplayName: "Preview Mac",
            itemID: "permission-preview",
            workstreamID: "claude-permission-preview",
            source: "claude",
            kind: .permissionRequest,
            status: .pending,
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now.addingTimeInterval(-30),
            requestID: "permission-preview-request",
            toolName: "Bash",
            toolInput: "{\"command\":\"echo Allow events\"}",
            connectionStatus: .connected
        )

        let longRows = (0..<36).map { index in
            MobileAgentFeedItem(
                macDeviceID: "preview-mac",
                macDisplayName: "Preview Mac",
                itemID: "scroll-preview-\(index)",
                workstreamID: "codex-scroll-preview-\(index)",
                source: "codex",
                kind: .stop,
                status: .telemetry,
                createdAt: now.addingTimeInterval(TimeInterval(-100 - index)),
                updatedAt: now.addingTimeInterval(TimeInterval(-100 - index)),
                stopReason: "Scroll fixture \(index). The prepared Feed row keeps enough Markdown and text to exercise repeated list layout without creating an empty event.",
                fullTextPreview: "Scroll fixture \(index). The prepared Feed row keeps enough Markdown and text to exercise repeated list layout without creating an empty event.",
                fullTextTruncated: true,
                connectionStatus: .connected
            )
        }

        let emptyAssistant = MobileAgentFeedItem(
            macDeviceID: "preview-mac",
            macDisplayName: "Preview Mac",
            itemID: "empty-assistant",
            workstreamID: "empty-assistant",
            source: "codex",
            kind: .assistantMessage,
            status: .telemetry,
            createdAt: now.addingTimeInterval(-10),
            updatedAt: now.addingTimeInterval(-10),
            connectionStatus: .connected
        )
        let emptyStop = MobileAgentFeedItem(
            macDeviceID: "preview-mac",
            macDisplayName: "Preview Mac",
            itemID: "empty-stop",
            workstreamID: "empty-stop",
            source: "codex",
            kind: .stop,
            status: .telemetry,
            createdAt: now.addingTimeInterval(-11),
            updatedAt: now.addingTimeInterval(-11),
            connectionStatus: .connected
        )
        return [question, permission] + longRows + [emptyAssistant, emptyStop]
    }

    private var rootToolbar: some ToolbarContent {
        WorkspaceRootToolbarContent(
            openSettings: {},
            openDevices: {},
            title: "All Computers",
            isLoading: false,
            selection: .all,
            select: { _ in },
            machines: [],
            showAddDevice: nil
        )
    }
}
#endif
