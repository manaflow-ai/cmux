import Foundation

@MainActor
struct FileExplorerWorkspaceRootResolver {
    func resolve(
        workspace: Workspace,
        detectedSSHSession: DetectedSSHSession?
    ) -> FileExplorerWorkspaceRoot {
        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            return .none
        }
        return .local(workspaceId: workspace.id, path: directory)
    }
}
