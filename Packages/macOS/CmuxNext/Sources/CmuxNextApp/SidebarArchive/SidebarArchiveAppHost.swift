import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextSidebarActions

/// The App's side of the archive actions (CmuxNextSidebarActions): the document item behind a targeted
/// workspace, each selected row and a targeted group; a workspace not placed yet cannot be archived.
@MainActor
final class SidebarArchiveAppHost: SidebarArchiveHost {
    private let context: AppActionContext
    init(_ context: AppActionContext) { self.context = context }
    func archiveItem(workspace invocation: ActionInvocation) throws -> String { try item(context.workspace(invocation).model.id) }
    func archiveItems(rows invocation: ActionInvocation) throws -> [String] {
        try WindowMembershipHandlers.rowTargets(invocation, context).map { try item($0.id) }
    }
    func archiveGroupID(_ invocation: ActionInvocation) throws -> String { try context.group(invocation).id.rawValue }
    func archiveRefusal(_ error: any Error) -> String { RefusalStrings.describe(error) }
    private func item(_ workspace: String) throws -> String {
        guard let item = SidebarDocWiring.item(workspace: workspace, context.services.machines) else {
            throw ArchiveRefusal(message: SidebarArchiveActions.notPlacedYet)
        }
        return item
    }
}
