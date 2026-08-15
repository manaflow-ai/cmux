import Foundation

/// Resolves the effective local working directory to diff for a workspace.
///
/// Order: focused local panel's effective directory → requested directory →
/// workspace resolved working directory. Remote workspaces / remote terminal
/// panels resolve to `nil` (shown as unavailable).
struct WorkspaceGitDiffDirectoryResolver {
    @MainActor
    func resolvedDirectory(
        for workspace: Workspace,
        focusedPanelId: UUID?
    ) -> String? {
        guard !(workspace.isRemoteWorkspace || workspace.isRemoteTmuxMirror) else {
            return nil
        }
        if let focusedPanelId, workspace.isRemoteTerminalSurface(focusedPanelId) {
            return nil
        }
        let candidates = [
            focusedPanelId.flatMap { workspace.panelDirectories[$0] },
            focusedPanelId.flatMap { workspace.terminalPanel(for: $0)?.requestedWorkingDirectory },
            workspace.currentDirectory,
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
