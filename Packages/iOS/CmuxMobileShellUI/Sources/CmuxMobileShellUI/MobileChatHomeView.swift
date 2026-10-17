import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// The chat-first shell shown after authentication and computer connection.
/// The native, chat-first iOS shell for connected cmux computers.
public struct MobileChatHomeView: View {
    @Bindable var store: CMUXMobileShellStore

    let isRestoringStoredMac: Bool
    let showSettings: () -> Void
    let showComputers: () -> Void
    let showAddDevice: (() -> Void)?
    private let usesPreviewData: Bool

    @State private var model: MobileChatHomeModel
    @State private var navigationPath: [MobileChatRoute] = []
    @State private var selectedTab: MobileChatTab = .chat
    @State private var isShowingNewChat = false

    /// Creates the chat shell.
    /// - Parameters:
    ///   - store: The authenticated mobile shell store.
    ///   - isRestoringStoredMac: Whether the saved computer is still reconnecting.
    ///   - showSettings: Action for opening the app settings surface.
    ///   - showComputers: Action for opening the computer picker.
    ///   - showAddDevice: Optional action for adding a computer from the empty state.
    ///   - previewData: Whether to render deterministic preview conversations.
    public init(
        store: CMUXMobileShellStore,
        isRestoringStoredMac: Bool = false,
        showSettings: @escaping () -> Void = {},
        showComputers: @escaping () -> Void = {},
        showAddDevice: (() -> Void)? = nil,
        previewData: Bool = false
    ) {
        self.store = store
        self.isRestoringStoredMac = isRestoringStoredMac
        self.showSettings = showSettings
        self.showComputers = showComputers
        self.showAddDevice = showAddDevice
        self.usesPreviewData = previewData
        _model = State(initialValue: MobileChatHomeModel())
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $navigationPath) {
                MobileChatsListView(
                    sessions: model.sessions,
                    isLoading: model.isLoadingSessions,
                    errorMessage: model.errorMessage,
                    isRestoringStoredMac: isRestoringStoredMac,
                    computerName: store.connectedHostName,
                    onSelect: { sessionID in
                        model.open(sessionID: sessionID)
                        navigationPath.append(.conversation(sessionID))
                    },
                    onNewChat: { isShowingNewChat = true },
                    onSettings: showSettings,
                    onComputers: showComputers,
                    onAddDevice: showAddDevice
                )
                .navigationDestination(for: MobileChatRoute.self) { route in
                    switch route {
                    case .conversation(let sessionID):
                        MobileChatConversationView(
                            sessionID: sessionID,
                            model: model,
                            onBack: { navigationPath.removeLast() }
                        )
                    }
                }
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(MobileChatTab.chat)
            .accessibilityIdentifier("MobilePrimaryTabChat")

            NavigationStack {
                MobileChatActivityView(
                    sessions: model.sessions,
                    onNewChat: { isShowingNewChat = true }
                )
            }
            .tabItem {
                Label("Activity", systemImage: "clock.arrow.circlepath")
            }
            .tag(MobileChatTab.activity)
            .accessibilityIdentifier("MobilePrimaryTabActivity")
        }
        .accessibilityIdentifier("MobileChatTabs")
        .sheet(isPresented: $isShowingNewChat) {
            MobileChatNewChatSheet(
                store: store,
                onChooseComputer: {
                    isShowingNewChat = false
                    showComputers()
                }
            ) { provider, prompt in
                model.insertPlaceholder(for: provider, title: prompt)
                Task { await model.refresh(using: store) }
            }
        }
        .task(id: store.connectionState) {
            if usesPreviewData {
                model.loadPreview()
            } else {
                await model.refresh(using: store)
            }
        }
        .onChange(of: store.connectedMacDeviceID) { _, _ in
            Task { await model.refresh(using: store) }
        }
    }
}

private enum MobileChatTab: Hashable {
    case chat
    case activity
}

private enum MobileChatRoute: Hashable {
    case conversation(String)
}
