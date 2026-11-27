import CmuxNextDaemon
import CmuxNextSidebar

extension AppServices {
    /// The name `workspace` shows now, as its sidebar row and its window's titlebar show it: the name the user gave,
    /// else the name its front tab gives it, read with the selection of the window that shows it. Every rename prompt
    /// starts from it and every palette list shows it. A Chief subagent's workspace reads as its task title.
    /// It reads this workspace's own facts only (its owner's registry entry, the daemon that holds its model), never a
    /// workspace list: one observer per workspace calls it (the link places), and a list read here made one workspace
    /// made or closed name every workspace of the session again (WORKSPACE LIST 800).
    // perf-hot: O(changed) workspace-list-change (one workspace's shown name: it reads no workspace list)
    func shownWorkspaceName(_ workspace: WorkspaceModel) -> String {
        let window = windows.registry.owner(ofWorkspace: workspace.id).flatMap(windows.controller(for:)) ?? windows.active
        let selection = window?.state.selection
        let name = WorkspaceAutoNameWiring(services: self, workspace: workspace).reader.titlebarName(workspace) { selection?.selection(in: $0.id) }
        guard let daemon = machines.daemon(holding: workspace), MachineID(daemon.machineID).isLocalChief else { return name }
        return name.chiefTaskTitle ?? name
    }
}
