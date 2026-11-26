#if os(iOS) && DEBUG
import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import SwiftUI

/// A small DEBUG-only iOS host for exercising the shared Feed and agent chat views.
/// This intentionally reports its platform and the styling gap instead of presenting
/// the result as a native macOS capture.
public struct B8bIOSHarnessRoot: View {
    private enum Surface: Hashable {
        case feed
        case chat
    }

    @State private var appStore: AppStore
    @State private var selectedSurface: Surface = .feed
    @State private var feedPath: [AgentChatDestination] = []
    @State private var chatStore: AgentChatStore

    public static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmux-mobile-b8b-harness")
    }

    public init() {
        let store = AppStore.mock()
        AgentSessionDirectory.shared.removeAll()
        AgentSessionDirectory.shared.makeSource = { summary in
            MockAgentSession(summary: summary, richFirstTurn: false, history: true)
        }
        guard let workspace = store.workspaces.first(where: { $0.id == "ws-cmux" }),
              let tab = workspace.tabs.first(where: { $0.id == "t-claude" }) else {
            preconditionFailure("B8b harness mock data must include ws-cmux/t-claude")
        }

        _appStore = State(initialValue: store)
        _chatStore = State(initialValue: AgentSessionDirectory.shared.store(
            workspace: workspace,
            tab: tab,
            macName: "Harness Mac"
        ))
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text("iOS host · AppKit/macOS styling gaps remain")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityIdentifier("b8b.harness.annotation")

            TabView(selection: $selectedSurface) {
                // FeedScreen owns its NavigationStack and chat destinations.
                FeedScreen(path: $feedPath) {
                    B8bHarnessToolbar()
                }
                .tabItem { Label("Feed", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(Surface.feed)

                NavigationStack {
                    AgentChatScreen(store: chatStore)
                }
                .tabItem { Label("Agent chat", systemImage: "message") }
                .tag(Surface.chat)
            }
        }
        .environment(appStore)
    }
}

private struct B8bHarnessToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            EmptyView()
        }
    }
}
#endif
