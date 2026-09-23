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
    /// Claude Desktop profile (account) name; each name keeps its own sign-in.
    let desktopProfile: String
    let rendererSession = AgentSessionWebRendererSession()

    private(set) var currentProviderID: AgentSessionProviderID
    private(set) var displayTitle: String
    var onRunCommand: ((String) throws -> [String: Any])? {
        didSet {
            rendererSession.onRunCommand = onRunCommand
        }
    }
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
        desktopProfile: String? = nil
    ) {
        let resolvedProviderID: AgentSessionProviderID = rendererKind == .claudeDesktop
            ? .claude
            : initialProviderID
        self.id = UUID()
        self.workspaceId = workspaceId
        self.rendererKind = rendererKind
        self.initialProviderID = resolvedProviderID
        self.currentProviderID = resolvedProviderID
        self.workingDirectory = workingDirectory
        self.desktopProfile = Self.normalizedDesktopProfile(desktopProfile)
        self.displayTitle = rendererKind == .claudeDesktop
            ? Self.desktopTitle(profile: self.desktopProfile)
            : Self.title(provider: resolvedProviderID, rendererKind: rendererKind)
        self.rendererSession.onHasActiveProviderChanged = { [weak self] hasActiveProvider in
            self?.setHasActiveProvider(hasActiveProvider)
        }
        self.rendererSession.onProviderIDChanged = { [weak self] providerID in
            self?.setCurrentProviderID(providerID)
        }
        if rendererKind == .claudeDesktop {
            // The panel, not its view, keeps the profile's process alive.
            ClaudeDesktopProfiles.registry.claim(
                profile: self.desktopProfile,
                panelID: self.id
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

    /// Maps a user-supplied profile name to a safe directory component.
    nonisolated static func normalizedDesktopProfile(_ raw: String?) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String((raw ?? "").lowercased().unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return cleaned.isEmpty ? "default" : cleaned
    }

    nonisolated static func desktopTitle(profile: String) -> String {
        let format = String(localized: "agentSession.panel.title", defaultValue: "%@ · %@")
        return String(format: format, AgentSessionProviderID.claude.displayName, profile)
    }

    func focus() {
        rendererSession.focus()
    }

    func unfocus() {
        rendererSession.unfocus()
    }

    func close() {
        rendererSession.close()
        if rendererKind == .claudeDesktop {
            // Real close only (moves and re-renders never call this). Ends the
            // Claude process when no other open panel uses the profile.
            ClaudeDesktopProfiles.registry.releasePanel(id)
        }
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
