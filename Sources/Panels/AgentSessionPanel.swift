import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AgentSessionPanel: Panel {
    @ObservationIgnored let id: UUID
    @ObservationIgnored let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    @ObservationIgnored let panelType: PanelType = .agentSession
    @ObservationIgnored private(set) var workspaceId: UUID
    @ObservationIgnored let rendererKind: AgentSessionRendererKind
    @ObservationIgnored let initialProviderID: AgentSessionProviderID
    @ObservationIgnored private(set) var workingDirectory: String?
    @ObservationIgnored let rendererSession = AgentSessionWebRendererSession()

    @ObservationIgnored private(set) var currentProviderID: AgentSessionProviderID
    @ObservationIgnored private(set) var displayTitle: String
    var displayIcon: String? { "sparkles.rectangle.stack" }
    @ObservationIgnored private(set) var isDirty: Bool = false
    @ObservationIgnored var onDisplayStateChanged: ((String, Bool) -> Void)? {
        didSet {
            onDisplayStateChanged?(displayTitle, isDirty)
        }
    }

    init(
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID = .codex,
        workingDirectory: String? = nil
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rendererKind = rendererKind
        self.initialProviderID = initialProviderID
        self.currentProviderID = initialProviderID
        self.workingDirectory = workingDirectory
        self.displayTitle = Self.title(provider: initialProviderID, rendererKind: rendererKind)
        self.rendererSession.onHasActiveProviderChanged = { [weak self] hasActiveProvider in
            self?.setHasActiveProvider(hasActiveProvider)
        }
        self.rendererSession.onProviderIDChanged = { [weak self] providerID in
            self?.setCurrentProviderID(providerID)
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

    func clearWorkingDirectory() {
        workingDirectory = nil
    }

    private func setHasActiveProvider(_ hasActiveProvider: Bool) {
        guard isDirty != hasActiveProvider else { return }
        isDirty = hasActiveProvider
        emitDisplayStateChanged()
    }

    private func setCurrentProviderID(_ providerID: AgentSessionProviderID) {
        guard currentProviderID != providerID else { return }
        currentProviderID = providerID
        displayTitle = Self.title(provider: providerID, rendererKind: rendererKind)
        emitDisplayStateChanged()
    }

    private func emitDisplayStateChanged() {
        onDisplayStateChanged?(displayTitle, isDirty)
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
