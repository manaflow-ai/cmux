import AppKit
import CmuxAcpmux
import Foundation
import Observation

/// The agent chat panel. It renders an acpmux session in the native ``AcpmuxChatPaneView``.
///
/// `PanelType.agentSession` and its snapshot keep their persisted names so sessions saved
/// by the older web renderer restore into this pane.
@MainActor
final class AgentSessionPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .agentSession
    private(set) var workspaceId: UUID
    /// Kept for snapshot compatibility with the retired web renderer.
    let rendererKind: AgentSessionRendererKind
    let initialProviderID: AgentSessionProviderID
    private(set) var workingDirectory: String?
    /// The legacy web renderer, unreferenced by the native pane. Deleted with the web renderer files.
    private(set) lazy var rendererSession = AgentSessionWebRendererSession()
    /// The chat state: daemon connection, selected acpmux session, and transcript.
    let chatModel: AcpmuxChatSessionModel
    private var chatPane: AcpmuxChatPaneView?

    private(set) var currentProviderID: AgentSessionProviderID
    private(set) var displayTitle: String
    /// Composer command routing from the web renderer. The native pane does not run terminal commands.
    var onRunCommand: ((String) throws -> [String: Any])?
    var displayIcon: String? { "bubble.left.and.bubble.right" }
    private(set) var isDirty: Bool = false
    var onDisplayStateChanged: ((String, Bool) -> Void)? {
        didSet {
            onDisplayStateChanged?(displayTitle, isDirty)
        }
    }

    /// The acpmux session shown by this panel, persisted in the session snapshot.
    var acpmuxSessionId: String? { chatModel.sessionId }

    init(
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID = .codex,
        workingDirectory: String? = nil,
        acpmuxSessionId: String? = nil,
        connector: (any AcpmuxConnecting)? = nil
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rendererKind = rendererKind
        self.initialProviderID = initialProviderID
        self.currentProviderID = initialProviderID
        self.workingDirectory = workingDirectory
        self.displayTitle = Self.defaultTitle
        self.chatModel = AcpmuxChatSessionModel(
            connector: connector ?? AcpmuxChatConnectorFactory(
                bundle: .main,
                processEnvironment: ProcessInfo.processInfo.environment,
                fileManager: .default
            ).makeConnector(),
            sessionId: acpmuxSessionId,
            workingDirectory: workingDirectory
        )
        chatModel.newSessionHarness = initialProviderID.acpmuxHarness
        observeChatModel()
    }

    nonisolated static var defaultTitle: String {
        String(localized: "acpmuxChat.panel.title", defaultValue: "Agent Chat")
    }

    /// The pane view, created on first use and reused across SwiftUI updates.
    ///
    /// The daemon connection starts here, when the pane first shows, so restored but
    /// never-viewed panels and unit tests that build panels do not contact acpmux.
    func chatPaneView(theme: AcpmuxChatTheme) -> AcpmuxChatPaneView {
        if let chatPane { return chatPane }
        let pane = AcpmuxChatPaneView(model: chatModel, theme: theme)
        chatPane = pane
        chatModel.start()
        return pane
    }

    private func observeChatModel() {
        withObservationTracking {
            let title = chatModel.summary?.displayTitle ?? Self.defaultTitle
            let working = chatModel.isWorking
            if title != displayTitle || working != isDirty {
                displayTitle = title
                isDirty = working
                onDisplayStateChanged?(displayTitle, isDirty)
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeChatModel() }
        }
    }

    func focus() {
        chatPane?.focusComposer()
    }

    /// Types `text` into the composer; each newline sends the composed message, as Return does.
    /// This is the `surface.send_text` path for agent chat surfaces.
    func receiveComposerInput(_ text: String) {
        if let chatPane {
            chatPane.receiveComposerInput(text)
            return
        }
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            chatModel.send(String(line))
        }
    }

    func unfocus() {}

#if DEBUG
    /// Scripted pane interactions for DEBUG animation recordings.
    func performDebugChatAction(_ action: String, params: [String: Any]) -> [String: Any]? {
        chatPane?.performDebugAction(action, params: params)
    }
#endif

    func close() {
        chatModel.stop()
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func clearWorkingDirectory() {
        workingDirectory = nil
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
