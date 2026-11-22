import CmuxNextControl

extension AppServices: BrowserAgentWorkspaceHost {
    func openAgentTab(url: String?, inWorkspace workspace: String?, named name: String) async throws -> (tab: String, workspace: String) { try await AgentBrowserProfile.openTab(url: url, inWorkspace: workspace, named: name, services: self) }
}
