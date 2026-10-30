import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextSidebarActions

extension AppServices: SidebarArchiveHost {
    func archiveWorkspace(_ invocation: ActionInvocation) throws -> String { try AppActionContext(services: self).workspace(invocation).model.id }
    func archiveRows(_ invocation: ActionInvocation) throws -> [String] { try WindowMembershipHandlers.rowTargets(invocation, AppActionContext(services: self)).map(\.id) }
    func archiveGroupID(_ invocation: ActionInvocation) throws -> String { try AppActionContext(services: self).group(invocation).id.rawValue }
    func archiveItem(workspace id: String) -> String? { SidebarDocWiring.item(workspace: id, machines) }
    func archiveRefusal(_ error: any Error) -> String { RefusalStrings.describe(error) }
}
