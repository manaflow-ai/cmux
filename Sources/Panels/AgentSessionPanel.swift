import AppKit
import Foundation

@MainActor
final class AgentSessionPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .agentSession
    private(set) var workspaceId: UUID
    let rendererKind: AgentSessionRendererKind
    let initialProviderID: AgentSessionProviderID
    private(set) var workingDirectory: String?
    private(set) var guiModeState: GuiModePanelState
    let rendererSession = AgentSessionWebRendererSession()

    private(set) var currentProviderID: AgentSessionProviderID
    private(set) var displayTitle: String
    var displayIcon: String? { rendererKind == .guiMode ? "macwindow" : "sparkles.rectangle.stack" }
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
        guiModeState: GuiModePanelState = .home
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rendererKind = rendererKind
        self.initialProviderID = initialProviderID
        self.currentProviderID = initialProviderID
        self.workingDirectory = workingDirectory
        self.guiModeState = guiModeState
        self.displayTitle = Self.title(provider: initialProviderID, rendererKind: rendererKind, guiModePage: guiModeState.page)
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
            return guiModePage == .taskWorktreePR
                ? String(localized: "guiMode.task.panel.title", defaultValue: "/task-worktree-pr")
                : String(localized: "guiMode.panel.title", defaultValue: "GUI Mode")
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

    func clearWorkingDirectory() {
        workingDirectory = nil
    }

    var guiModePage: GuiModePanelPage { guiModeState.page }
    var guiModePrompt: String? { guiModeState.prompt }
    var guiModeProviderID: GuiModeProviderID { guiModeState.providerID }

    func configureGuiModeTask(prompt: String, providerID: GuiModeProviderID) {
        guard rendererKind == .guiMode else { return }
        guiModeState = .taskWorktreePR(prompt: prompt, providerID: providerID)
        displayTitle = Self.title(provider: currentProviderID, rendererKind: rendererKind, guiModePage: guiModeState.page)
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
        displayTitle = Self.title(provider: providerID, rendererKind: rendererKind, guiModePage: guiModeState.page)
        emitDisplayStateChanged()
    }

    private func emitDisplayStateChanged() {
        onDisplayStateChanged?(displayTitle, isDirty)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
