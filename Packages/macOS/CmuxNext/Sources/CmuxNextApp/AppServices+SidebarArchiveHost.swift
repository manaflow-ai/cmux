import CmuxNextActions
import CmuxNextDaemonService
import CmuxNextSidebar
import CmuxNextSidebarActions

extension AppServices: SidebarArchiveHost {
    func archiveWorkspace(_ invocation: ActionInvocation) throws -> String { try AppActionContext(services: self).workspace(invocation).model.id }
    func archiveRows(_ invocation: ActionInvocation, closedBy close: ActionID?) throws -> [String] { let context = AppActionContext(services: self); return try close.map { try WorkspaceBulkClose.plan($0, invocation, context).0.filter { !$0.0.pinned }.map(\.0.id) } ?? WindowMembershipHandlers.rowTargets(invocation, context).map(\.id) }
    func archiveGroupID(_ invocation: ActionInvocation) throws -> String { try AppActionContext(services: self).group(invocation).id.rawValue }
    func archiveItem(workspace id: String) -> String? { sidebarDoc.item(workspace: id) }
    func archiveRefusal(_ error: any Error) -> String { RefusalStrings.describe(error) }
    var archiveDocument: SidebarDocStore? { sidebarDoc.store }
    var archiveSections: [SidebarSection]? { windows.controllers.isEmpty ? nil : windows.controllers.flatMap(\.sidebar.model.sections) }
    func archiveOpen(_ entry: SidebarArchivedEntry) { guard let window = windows.active ?? windows.controllers.first else { return }; if entry.kind == .workspace { SidebarNavigation.activate(.workspace(WorkspaceID(entry.id)), in: window, self) } else { window.sidebar.activateLayoutItem(LayoutItemID(entry.id)) } }
    func archiveDelete(_ entry: SidebarArchivedEntry) -> String? { registry.reportingRefusal { _ = entry.kind == .workspace ? self.registry.perform("closeWorkspace", invocation: ActionInvocation(closingRow: entry.id)) : self.registry.perform("sidebar.item.remove", invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: entry.id))) } }
}
