import Foundation

extension BrowserPanel {
    func sendDesignModePromptToAgent(
        _ prompt: String,
        replacingUnknownDraft: Bool
    ) async throws {
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: id,
            preferredWorkspaceId: workspaceId
        )?.workspace else {
            throw BrowserDesignModeSendError.terminalUnavailable
        }
        try await TerminalController.shared.sendDesignModePrompt(
            prompt,
            in: workspace,
            replacingUnknownDraft: replacingUnknownDraft
        )
    }
}
