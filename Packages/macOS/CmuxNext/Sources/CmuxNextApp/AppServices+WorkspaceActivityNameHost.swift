import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWorkspaceNaming

extension AppServices: WorkspaceActivityNameHost {
    func activityWorkspace(_ invocation: ActionInvocation) -> WorkspaceModel? { AppActionContext(services: self).scope(invocation).workspace }
    func activityPageTitle(_ tab: TabModel) -> String? { cache.browserTabs.isIncognitoTab(tab.id) ? nil : cache.existingBrowser(tab.id)?.tab.state.title }
    func activityHasAgents() -> Bool { QuitAgents.environment(self) != nil }
    func activityComplete(_ params: [String: any Sendable], fallback: [String: any Sendable]) async throws -> String { try await QuitAgents.environment(self)?.completionText(params: params, fallback: fallback) ?? "" }
    func activityRun(_ workspace: WorkspaceModel, _ body: @escaping @Sendable (isolated DaemonConnection) async throws -> Void) async -> Bool { await activityDaemon(workspace).run("name-from-activity", body) }
    func activityGuardsRevision(_ workspace: WorkspaceModel) -> Bool { activityDaemon(workspace).supports(DaemonCapability.workspaceNameSource.rawValue) }
    private func activityDaemon(_ workspace: WorkspaceModel) -> DaemonService { machines.daemon(forWorkspace: workspace.id) ?? activeDaemon }
}
