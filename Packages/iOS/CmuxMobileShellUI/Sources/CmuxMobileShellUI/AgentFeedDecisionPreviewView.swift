#if DEBUG && os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import os
import SwiftUI

/// Deterministic Feed fixture for the decision controls and long-list scroll
/// path. It uses the production Feed view so screenshots exercise row identity,
/// filtering, paging, Markdown rendering, and action layout together.
public struct AgentFeedDecisionPreviewView: View {
    @State private var selectedTab: MobilePrimaryTab = .feed
    @State private var searchCoordinator = MobilePrimarySearchCoordinator(initialScope: .feed)
    @State private var path: [String] = []
    @State private var stressMonitor = AgentFeedScrollStressFrameMonitor()
    @State private var stressMetrics = "state=idle"
    @State private var referenceDate: Date
    @State private var items: [MobileAgentFeedItem]
    @State private var itemsRevision = 0

    public init() {
        let referenceDate = Date()
        _referenceDate = State(initialValue: referenceDate)
        _items = State(initialValue: Self.makeItems(
            referenceDate: referenceDate,
            longRowCount: UITestConfig.agentFeedDecisionPreviewItemCount ?? 36
        ))
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
                    itemsRevision: AgentFeedItemsRevision(sourceRevision: UInt64(itemsRevision)),
                    status: .ready,
                    pendingReplyRequestIDs: [],
                    pendingTerminalReplyItemIDs: [],
                    refreshesOnAppear: false,
                    actions: actions,
                    searchText: searchCoordinator.searchDestinationText(for: .feed),
                    performanceObserver: UITestConfig.agentFeedDecisionPreviewScrollStressEnabled ? stressMonitor : nil
                )
                .toolbar { rootToolbar }
                .navigationDestination(for: String.self) { destination in
                    Text(verbatim: "Opened preview " + destination)
                }
            }
        } notifications: {
            NavigationStack { Text(verbatim: "Notifications").toolbar { rootToolbar } }
        } cloud: {
            NavigationStack { Text(verbatim: "Cloud").toolbar { rootToolbar } }
        } search: {
            MobilePrimarySearchNavigationStack(
                path: .constant([]),
                selection: $selectedTab,
                searchCoordinator: searchCoordinator
            ) {
                AgentFeedView(
                    items: items,
                    itemsRevision: AgentFeedItemsRevision(sourceRevision: UInt64(itemsRevision)),
                    status: .ready,
                    pendingReplyRequestIDs: [],
                    pendingTerminalReplyItemIDs: [],
                    refreshesOnAppear: false,
                    actions: actions,
                    searchText: searchCoordinator.searchDestinationText(for: .feed)
                )
            } destination: { _ in EmptyView() }
        }
        .background {
            if UITestConfig.agentFeedDecisionPreviewScrollStressEnabled {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("AgentFeedScrollStressMetrics")
                    .accessibilityValue(stressMetrics)
            }
        }
        .preferredColorScheme(UITestConfig.agentFeedDecisionPreviewLightAppearanceEnabled ? .light : .dark)
        .task {
            await runScrollStressIfEnabled()
        }
    }

    private var actions: AgentFeedActions {
        AgentFeedActions(
            permissionReply: { item, mode in
                resolve(item, decision: MobileAgentFeedDecision(kind: "permission", mode: mode))
            },
            questionReply: { item, answers in
                resolve(item, decision: MobileAgentFeedDecision(kind: "question", selections: answers))
            },
            openDestination: { item in path = [item.remoteSurfaceID == nil ? "workspace" : "tab"] },
            loadFullText: { item in item.fullTextPreview ?? item.stopReason ?? "" }
        )
    }

    private func resolve(_ item: MobileAgentFeedItem, decision: MobileAgentFeedDecision) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item.updating(status: .resolved(decision))
        itemsRevision &+= 1
    }

    private static func makeItems(
        referenceDate now: Date,
        longRowCount: Int
    ) -> [MobileAgentFeedItem] {
        let richText = UITestConfig.agentFeedQuestionMarkdownPreviewEnabled
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
                    prompt: richText ? "Where should **this release** deploy?" : "Where should this deploy?",
                    options: [
                        MobileAgentFeedQuestionOption(
                            id: "production",
                            label: richText ? "**Production**" : "Production",
                            description: richText ? "Deploy the `release` to production." : "Deploy the current release to production."
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
            ].filter { !richText || $0.id == "deploy" },
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

        let longRows = (0..<longRowCount).map { index in
            makeScrollRow(
                itemID: "scroll-preview-\(index)",
                createdAt: now.addingTimeInterval(TimeInterval(-100 - index))
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

    private static func makeScrollRow(itemID: String, createdAt: Date) -> MobileAgentFeedItem {
        MobileAgentFeedItem(
            macDeviceID: "preview-mac",
            macDisplayName: "Preview Mac",
            itemID: itemID,
            workstreamID: "codex-\(itemID)",
            source: "codex",
            kind: .stop,
            status: .telemetry,
            createdAt: createdAt,
            updatedAt: createdAt,
            stopReason: "Scroll fixture \(itemID). The prepared Feed row keeps enough Markdown and text to exercise repeated list layout without creating an empty event.",
            fullTextPreview: "Scroll fixture \(itemID). The prepared Feed row keeps enough Markdown and text to exercise repeated list layout without creating an empty event.",
            fullTextTruncated: true,
            connectionStatus: .connected
        )
    }

    private func runScrollStressIfEnabled() async {
        guard UITestConfig.agentFeedDecisionPreviewScrollStressEnabled else { return }

        let monitor = stressMonitor
        monitor.start()
        stressMetrics = monitor.markerValue(state: "running")
        let clock = ContinuousClock()
        defer {
            monitor.stop()
            let state = Task.isCancelled ? "cancelled" : "complete"
            stressMetrics = monitor.markerValue(state: state)
            Logger(subsystem: "dev.cmux.ios", category: "AgentFeedScrollStress").notice(
                "AFSCROLLSTRESS \(self.stressMetrics, privacy: .public)"
            )
        }

        for index in 0..<60 {
            guard !Task.isCancelled else { return }
            do {
                try await clock.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            injectStressRow(index)
        }
    }

    private func injectStressRow(_ index: Int) {
        let row = Self.makeScrollRow(
            itemID: "scroll-stress-\(index)",
            createdAt: referenceDate.addingTimeInterval(TimeInterval(-100 - index))
        )
        items.insert(row, at: min(2, items.count))
        if let oldRowIndex = items.lastIndex(where: { item in
            (item.itemID.hasPrefix("scroll-preview-")
                || item.itemID.hasPrefix("scroll-stress-"))
                && item.id != row.id
        }) {
            items.remove(at: oldRowIndex)
        }
        itemsRevision &+= 1
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
