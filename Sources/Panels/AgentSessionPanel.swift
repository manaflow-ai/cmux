import AppKit
import Foundation

enum GuiModePanelPage: String, Sendable {
    case home
    case taskWorktreePR = "task-worktree-pr"
}

struct GuiModePanelInitialState: Equatable, Sendable {
    let page: GuiModePanelPage
    let prompt: String?
    let providerID: GuiModeProviderID

    static let home = GuiModePanelInitialState(page: .home, prompt: nil, providerID: .codex)

    static func taskWorktreePR(prompt: String, providerID: GuiModeProviderID) -> GuiModePanelInitialState {
        GuiModePanelInitialState(page: .taskWorktreePR, prompt: prompt, providerID: providerID)
    }
}

@MainActor
final class AgentSessionPanel: Panel {
    let id: UUID
    let panelType: PanelType = .agentSession
    private(set) var workspaceId: UUID
    let rendererKind: AgentSessionRendererKind
    let initialProviderID: AgentSessionProviderID
    let workingDirectory: String?
    let rendererSession = AgentSessionWebRendererSession()
    private(set) var guiModePage: GuiModePanelPage
    private(set) var guiModePrompt: String?
    private(set) var guiModeProviderID: GuiModeProviderID

    private(set) var currentProviderID: AgentSessionProviderID
    private(set) var displayTitle: String
    var displayIcon: String? { "sparkles.rectangle.stack" }
    private(set) var isDirty: Bool = false
    var onDisplayStateChanged: ((String, Bool) -> Void)? {
        didSet {
            onDisplayStateChanged?(displayTitle, isDirty)
        }
    }

    init(
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID = .codex,
        workingDirectory: String? = nil,
        guiModePage: GuiModePanelPage = .home,
        guiModePrompt: String? = nil,
        guiModeProviderID: GuiModeProviderID = .codex
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rendererKind = rendererKind
        self.initialProviderID = initialProviderID
        self.currentProviderID = initialProviderID
        self.workingDirectory = workingDirectory
        self.guiModePage = guiModePage
        self.guiModePrompt = guiModePrompt
        self.guiModeProviderID = guiModeProviderID
        self.displayTitle = Self.title(
            provider: initialProviderID,
            rendererKind: rendererKind,
            guiModePage: guiModePage
        )
        self.rendererSession.onHasActiveProviderChanged = { [weak self] hasActiveProvider in
            self?.setHasActiveProvider(hasActiveProvider)
        }
        self.rendererSession.onProviderIDChanged = { [weak self] providerID in
            self?.setCurrentProviderID(providerID)
        }
    }

    nonisolated static func title(
        provider: AgentSessionProviderID,
        rendererKind: AgentSessionRendererKind,
        guiModePage: GuiModePanelPage = .home
    ) -> String {
        if rendererKind == .guiMode {
            if guiModePage == .taskWorktreePR {
                return String(localized: "guiMode.task.panel.title", defaultValue: "/task-worktree-pr")
            }
            return String(localized: "guiMode.panel.title", defaultValue: "GUI Mode")
        }
        let format = String(localized: "agentSession.panel.title", defaultValue: "%@ · %@")
        return String(format: format, provider.displayName, rendererKind.displayName)
    }

    func focus() {
        rendererSession.focus()
    }

    func unfocus() {
        rendererSession.unfocus()
    }

    func close() {
        rendererSession.close()
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func configureGuiModeTask(prompt: String, providerID: GuiModeProviderID) {
        guard rendererKind == .guiMode else { return }
        guiModePage = .taskWorktreePR
        guiModePrompt = prompt
        guiModeProviderID = providerID
        displayTitle = Self.title(
            provider: initialProviderID,
            rendererKind: rendererKind,
            guiModePage: guiModePage
        )
        emitDisplayStateChanged()
    }

    private func setHasActiveProvider(_ hasActiveProvider: Bool) {
        guard isDirty != hasActiveProvider else { return }
        isDirty = hasActiveProvider
        emitDisplayStateChanged()
    }

    private func setCurrentProviderID(_ providerID: AgentSessionProviderID) {
        guard currentProviderID != providerID else { return }
        currentProviderID = providerID
        displayTitle = Self.title(provider: providerID, rendererKind: rendererKind, guiModePage: guiModePage)
        emitDisplayStateChanged()
    }

    private func emitDisplayStateChanged() {
        onDisplayStateChanged?(displayTitle, isDirty)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
