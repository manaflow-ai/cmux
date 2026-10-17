import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// The chat-first shell shown after authentication and computer connection.
/// The native, chat-first iOS shell for connected cmux computers.
public struct MobileChatHomeView: View {
    @Bindable var store: CMUXMobileShellStore

    let isRestoringStoredMac: Bool
    let signOut: @MainActor @Sendable () -> Void
    let showSettings: () -> Void
    let showComputers: () -> Void
    let showAddDevice: (() -> Void)?
    private let usesPreviewData: Bool

    @State private var model: MobileChatHomeModel
    @State private var navigationPath: [MobileChatRoute] = []
    @State private var isShowingNewChat = false
    @State private var isShowingSidebar = false
    @State private var pendingLaunch: MobileChatLaunchRequest?

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
        signOut: @escaping @MainActor @Sendable () -> Void = {},
        showSettings: @escaping () -> Void = {},
        showComputers: @escaping () -> Void = {},
        showAddDevice: (() -> Void)? = nil,
        previewData: Bool = false
    ) {
        self.store = store
        self.isRestoringStoredMac = isRestoringStoredMac
        self.signOut = signOut
        self.showSettings = showSettings
        self.showComputers = showComputers
        self.showAddDevice = showAddDevice
        self.usesPreviewData = previewData
        _model = State(initialValue: MobileChatHomeModel())
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            MobileChatsListView(
                sessions: model.sessions,
                previewText: model.previewText(for:),
                isLoading: model.isLoadingSessions,
                errorMessage: model.errorMessage,
                isRestoringStoredMac: isRestoringStoredMac,
                computerName: store.connectedHostName,
                pendingLaunch: pendingLaunch,
                onSelect: openSession,
                onNewChat: { isShowingNewChat = true },
                onMenu: { isShowingSidebar = true },
                onComputers: showComputers,
                onAddDevice: showAddDevice,
                onRetry: { Task { await model.refresh(using: store) } }
            )
            .navigationDestination(for: MobileChatRoute.self) { route in
                switch route {
                case .conversation(let sessionID):
                    MobileChatConversationView(
                        sessionID: sessionID,
                        model: model,
                        onBack: { navigationPath.removeLast() },
                        onMenu: { isShowingSidebar = true }
                    )
                case .activity:
                    MobileChatActivityView(
                        sessions: model.sessions,
                        onSelect: openSession,
                        onNewChat: { isShowingNewChat = true }
                    )
                }
            }
        }
        .accessibilityIdentifier("MobileChatShell")
        .sheet(isPresented: $isShowingSidebar) {
            MobileChatSidebarView(
                sessions: model.sessions,
                previewText: model.previewText(for:),
                computerName: store.connectedHostName,
                onSelect: { sessionID in
                    isShowingSidebar = false
                    openSession(sessionID)
                },
                onNewChat: {
                    isShowingSidebar = false
                    isShowingNewChat = true
                },
                onActivity: {
                    isShowingSidebar = false
                    navigationPath.append(.activity)
                },
                onSettings: {
                    isShowingSidebar = false
                    showSettings()
                },
                onSignOut: {
                    isShowingSidebar = false
                    signOut()
                },
                onComputers: {
                    isShowingSidebar = false
                    showComputers()
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingNewChat) {
            MobileChatNewChatSheet(
                store: store,
                onChooseComputer: {
                    isShowingNewChat = false
                    showComputers()
                }
            ) { provider, prompt in
                pendingLaunch = MobileChatLaunchRequest(
                    provider: provider,
                    prompt: prompt,
                    existingSessionIDs: Set(model.sessions.map(\.id))
                )
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
        .onChange(of: model.sessions) { _, _ in
            resolvePendingLaunch()
        }
    }

    private func openSession(_ sessionID: String) {
        pendingLaunch = nil
        model.open(sessionID: sessionID)
        navigationPath.removeAll()
        navigationPath.append(.conversation(sessionID))
    }

    private func resolvePendingLaunch() {
        guard let pendingLaunch else { return }
        guard let session = model.sessions
            .filter({ !pendingLaunch.existingSessionIDs.contains($0.id) })
            .filter({ MobileChatProvider.resolve($0.agentKind) == pendingLaunch.provider })
            .sorted(by: { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) })
            .first(where: { candidate in
                guard let title = candidate.title?.lowercased() else { return true }
                let promptPrefix = pendingLaunch.prompt
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .prefix(24)
                return promptPrefix.isEmpty || title.contains(promptPrefix)
            }) else { return }
        self.pendingLaunch = nil
        openSession(session.id)
    }
}

struct MobileChatLaunchRequest: Equatable {
    let provider: MobileChatProvider
    let prompt: String
    let existingSessionIDs: Set<String>
}

private enum MobileChatRoute: Hashable {
    case conversation(String)
    case activity
}
