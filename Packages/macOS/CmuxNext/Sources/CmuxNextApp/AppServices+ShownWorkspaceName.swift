import CmuxNextDaemon
import CmuxNextSidebar

extension AppServices {
    /// The name `workspace` shows now, as its sidebar row and its window's titlebar show it: the
    /// name the user gave, else the name its front tab gives it (a terminal's OSC title, a page's,
    /// a chat's), read with the selection of the window that shows it. Every rename prompt starts
    /// from this name and every palette list shows it, so Rename Workspace (Cmd-Shift-R, the
    /// palette, a row's menu) never opens on the daemon's stored `workspace-N` while the row reads
    /// as its front tab. A Chief subagent's workspace reads as its task title, as its row does.
    func shownWorkspaceName(_ workspace: WorkspaceModel) -> String {
        let window = windows.registry.value.owner(of: workspace.id).flatMap(windows.controller(for:)) ?? windows.active
        let selection = window?.state.selection
        let name = WorkspaceAutoNameWiring(services: self).reader.titlebarName(workspace) { pane in
            selection?.selection(in: pane.id)
        }
        guard let daemon = machines.daemon(forWorkspace: workspace.id), MachineID(daemon.machineID).isLocalChief else { return name }
        return name.chiefTaskTitle ?? name
    }
}
