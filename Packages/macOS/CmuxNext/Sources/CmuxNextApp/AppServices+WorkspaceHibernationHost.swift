import CmuxNextHibernation

// Workspace hibernation (plans/cmux-next/workspace-hibernation-DESIGN.md): one-line forwards to the App's owners.
extension AppServices: WorkspaceHibernationHost {
    func hibernationResidents() -> [WorkspaceHibernationResident] { windows.hibernationResidents(in: machines.daemons.map(\.store), holdsMemory: holdsTabMemory) }
    func hibernationShownWorkspaces() -> Set<String> { windows.shownWorkspaceIDs }
    func hibernationPolicy() -> WorkspaceHibernationPlanner.Policy { WorkspaceHibernationPlanner.Policy(settings?.snapshot.workspaceHibernation) }
    func hibernate(workspace id: String) { hibernateWorkspace(id) }
}
