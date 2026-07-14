import Foundation

extension Workspace {
    /// Live local-directory candidates used to close tabs rooted in a removed worktree.
    func worktreeSidebarCandidateDirectories() -> [String] {
        guard !isRemoteWorkspace, !isRemoteTmuxMirror else { return [] }

        var directories = [currentDirectory]
        directories.append(contentsOf: panelDirectories.values)
        for panel in panels.values {
            if let terminalPanel = panel as? TerminalPanel,
               let requested = terminalPanel.requestedWorkingDirectory {
                directories.append(requested)
            }
            if let agentPanel = panel as? AgentSessionPanel,
               let workingDirectory = agentPanel.workingDirectory {
                directories.append(workingDirectory)
            }
        }
        return directories.filter { !$0.isEmpty }
    }
}
