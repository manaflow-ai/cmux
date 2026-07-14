import Foundation

extension BrowserPanel {
    @discardableResult
    func sendDesignModePromptToAgent(_ prompt: String) -> Bool {
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: workspaceId) else { return false }
        let browserPane = workspace.paneId(forPanelId: id)
        guard let terminal = workspace.terminalPanelForConfigInheritance(inPane: browserPane) else { return false }
        return terminal.sendText(prompt + "\r")
    }
}
