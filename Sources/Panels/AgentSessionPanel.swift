import AppKit
import Foundation

@MainActor
final class AgentSessionPanel: Panel {
    let id: UUID
    let panelType: PanelType = .agentSession
    private(set) var workspaceId: UUID
    let rendererKind: AgentSessionRendererKind
    let initialProviderID: AgentSessionProviderID
    let initialModelID: String?
    let initialOpenCodeProviderID: String?
    let workingDirectory: String?
    let rendererSession = AgentSessionWebRendererSession()

    private(set) var currentProviderID: AgentSessionProviderID
    private(set) var currentModelID: String?
    private(set) var currentOpenCodeProviderID: String?
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
        initialModelID: String? = nil,
        initialOpenCodeProviderID: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rendererKind = rendererKind
        self.initialProviderID = initialProviderID
        self.initialModelID = initialModelID
        self.initialOpenCodeProviderID = initialOpenCodeProviderID
        self.currentProviderID = initialProviderID
        self.currentModelID = initialModelID
        self.currentOpenCodeProviderID = initialProviderID == .opencode ? initialOpenCodeProviderID : nil
        self.workingDirectory = workingDirectory
        self.displayTitle = Self.title(provider: initialProviderID, rendererKind: rendererKind)
        self.rendererSession.onHasActiveProviderChanged = { [weak self] hasActiveProvider in
            self?.setHasActiveProvider(hasActiveProvider)
        }
        self.rendererSession.onProviderSelectionChanged = { [weak self] providerID, modelID, openCodeProviderID in
            self?.setCurrentProviderSelection(
                providerID: providerID,
                modelID: modelID,
                openCodeProviderID: openCodeProviderID
            )
        }
    }

    nonisolated static func title(
        provider: AgentSessionProviderID,
        rendererKind: AgentSessionRendererKind
    ) -> String {
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

    private func setHasActiveProvider(_ hasActiveProvider: Bool) {
        guard isDirty != hasActiveProvider else { return }
        isDirty = hasActiveProvider
        emitDisplayStateChanged()
    }

    private func setCurrentProviderSelection(
        providerID: AgentSessionProviderID,
        modelID: String?,
        openCodeProviderID: String?
    ) {
        let normalizedOpenCodeProviderID = providerID == .opencode ? openCodeProviderID : nil
        let providerChanged = currentProviderID != providerID
        let modelChanged = currentModelID != modelID
        let openCodeProviderChanged = currentOpenCodeProviderID != normalizedOpenCodeProviderID
        guard providerChanged || modelChanged || openCodeProviderChanged else { return }
        currentProviderID = providerID
        currentModelID = modelID
        currentOpenCodeProviderID = normalizedOpenCodeProviderID
        if providerChanged {
            displayTitle = Self.title(provider: providerID, rendererKind: rendererKind)
            emitDisplayStateChanged()
        }
    }

    private func emitDisplayStateChanged() {
        onDisplayStateChanged?(displayTitle, isDirty)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
