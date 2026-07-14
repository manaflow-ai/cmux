import Foundation

extension BrowserPanel {
    func sendDesignModePromptToAgent(
        _ prompt: String,
        replacingUnknownDraft: Bool,
        operationIsCurrent: @MainActor @Sendable () -> Bool
    ) async throws {
        guard let workspace = AppDelegate.shared?.workspaceForBrowserDesignModePanel(
            panelId: id,
            preferredWorkspaceId: workspaceId
        ) else {
            throw BrowserDesignModeSendError.terminalUnavailable
        }
        try await TerminalController.shared.sendDesignModePrompt(
            prompt,
            in: workspace,
            browserPanelID: id,
            replacingUnknownDraft: replacingUnknownDraft,
            operationIsCurrent: operationIsCurrent
        )
    }
}

extension AppDelegate {
    func workspaceForBrowserDesignModePanel(
        panelId: UUID,
        preferredWorkspaceId: UUID?
    ) -> Workspace? {
        if let owner = workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: preferredWorkspaceId
        ) {
            return owner.workspace
        }
        guard let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(panelId) }),
              let manager = dockReferenceTabManager(for: dock) else { return nil }
        if dock.scope == .workspace {
            return manager.tabs.first(where: { $0.id == dock.workspaceId })
        }
        return manager.selectedWorkspace
    }
}
