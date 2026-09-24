#if os(iOS) && DEBUG
import CmuxMobileShellModel
import SwiftUI

/// Isolated fixture that exercises the production row and reading sheet.
public struct AgentFeedFullTextPreviewView: View {
    @State private var attempts = 0
    @State private var selectedTab: MobilePrimaryTab = .feed
    @State private var searchCoordinator = MobilePrimarySearchCoordinator(initialScope: .feed)
    @State private var path: [String] = []
    private let failsOnce: Bool
    private let item: MobileAgentFeedItem
    private let fullText: String
    private let shortItem: MobileAgentFeedItem

    public init(failsOnce: Bool = false) {
        self.failsOnce = failsOnce
        let text = """
        **Markdown preview** with *emphasis*, `inline code`, and [a link](https://example.com/feed).

        ## Implementation notes

        - First item
        - Second item

        ```swift
        let message = "Hello, Feed"
        ```

        """ + (1...24).map { number in
            "Paragraph \(number). This response keeps its complete explanation, line breaks, and Unicode 👩🏽‍💻."
        }.joined(separator: "\n\n") + "\n\nFINAL PARAGRAPH: The complete response ends here."
        fullText = text
        let now = Date()
        item = MobileAgentFeedItem(
            macDeviceID: "preview-mac", macDisplayName: "Preview Mac",
            itemID: "full-text-preview", workstreamID: "codex-preview", source: "codex",
            kind: .stop, status: .telemetry, createdAt: now, updatedAt: now,
            stopReason: text, fullTextTruncated: false, connectionStatus: .connected
        )
        shortItem = MobileAgentFeedItem(
            macDeviceID: "preview-mac", macDisplayName: "Preview Mac",
            itemID: "short-text-preview", workstreamID: "codex-short", source: "codex",
            kind: .stop, status: .telemetry, createdAt: now, updatedAt: now,
            stopReason: "Stopped.", remoteWorkspaceID: "preview-workspace",
            remoteSurfaceID: "preview-tab", connectionStatus: .connected
        )
    }

    public var body: some View {
        MobilePrimaryTabScaffold(selection: $selectedTab, searchCoordinator: searchCoordinator,
                                 notificationUnreadCount: 0) {
            NavigationStack { Text(verbatim: "Workspaces").toolbar { rootToolbar } }
        } feed: {
            NavigationStack(path: $path) {
                feedContent
                    .toolbar { rootToolbar }
                    .navigationDestination(for: String.self) { destination in
                        Text(verbatim: "Opened preview " + destination)
                    }
            }
        } notifications: {
            NavigationStack { Text(verbatim: "Notifications").toolbar { rootToolbar } }
        } search: {
            MobilePrimarySearchNavigationStack(path: .constant([]), selection: $selectedTab,
                                               searchCoordinator: searchCoordinator) {
                feedContent.toolbar { rootToolbar }
            } destination: { _ in EmptyView() }
        }
    }

    private var feedContent: some View {
        AgentFeedView(
            items: [shortItem, item], status: .ready, pendingReplyRequestIDs: [],
            pendingTerminalReplyItemIDs: [], refreshesOnAppear: false,
            actions: AgentFeedActions(
                openDestination: { item in path = [item.remoteSurfaceID == nil ? "workspace" : "tab"] },
                loadFullText: { _ in
                    attempts += 1
                    if failsOnce && attempts == 1 { throw URLError(.notConnectedToInternet) }
                    return fullText
                }
            ),
            searchText: searchCoordinator.searchDestinationText(for: .feed)
        )
    }

    private var rootToolbar: some ToolbarContent {
        WorkspaceRootToolbarContent(openSettings: {}, openDevices: {}, title: "All Computers",
                                    isLoading: false, selection: .all, select: { _ in },
                                    machines: [], showAddDevice: nil)
    }
}
#endif
