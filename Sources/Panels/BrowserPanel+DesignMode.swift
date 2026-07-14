import Foundation

extension BrowserPanel {
    func sendDesignModePromptToAgent(_ prompt: String) throws {
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceId) else {
            throw BrowserDesignModeSendError.terminalUnavailable
        }
        try TerminalController.shared.sendDesignModePrompt(prompt, in: workspace)
    }
}
