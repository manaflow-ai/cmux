import Foundation

extension Workspace {
    /// Live local-directory candidates used to close tabs rooted in a removed worktree.
    func worktreeSidebarCandidateDirectories() -> [String] {
        guard !isRemoteWorkspace, !isRemoteTmuxMirror else { return [] }

        var directories: [String] = []
        for (panelID, panel) in panels {
            if let reported = panelDirectories[panelID],
               !reported.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                directories.append(reported)
            } else if let terminalPanel = panel as? TerminalPanel,
                      let requested = terminalPanel.requestedWorkingDirectory {
                directories.append(requested)
            } else if let agentPanel = panel as? AgentSessionPanel,
                      let workingDirectory = agentPanel.workingDirectory {
                directories.append(workingDirectory)
            }
        }
        if directories.isEmpty {
            directories.append(currentDirectory)
        }
        return directories.filter { !$0.isEmpty }
    }
}
