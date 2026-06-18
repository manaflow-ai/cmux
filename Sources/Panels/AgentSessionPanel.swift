import AppKit
import Foundation

@MainActor
final class AgentSessionPanel: Panel {
    let id: UUID
    let panelType: PanelType = .agentSession
    private(set) var workspaceId: UUID
    let rendererKind: AgentSessionRendererKind
    let initialProviderID: AgentSessionProviderID
    let workingDirectory: String?
    let rendererSession = AgentSessionWebRendererSession()

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


// MARK: - Find support

extension AgentSessionPanel: FindablePanel {
    /// Shows the web view's find panel.
    @discardableResult
    func startFind() -> Bool {
        sendFindPanelAction(.showFindInterface)
    }

    /// Jumps to the next match in the web view.
    func findNext() {
        _ = sendFindPanelAction(.nextMatch)
    }

    /// Jumps to the previous match in the web view.
    func findPrevious() {
        _ = sendFindPanelAction(.previousMatch)
    }

    /// Hiding the web view find panel is not supported by `WKWebView`.
    func hideFind() {}

    /// Sends a find action to the agent session web view.
    @discardableResult
    private func sendFindPanelAction(_ action: NSTextFinder.Action) -> Bool {
        guard let webView = rendererSession.webView else { return false }
        return NSApp.sendAction(
            NSSelectorFromString("performFindPanelAction:"),
            to: webView,
            from: action.menuItemSender
        )
    }
}
