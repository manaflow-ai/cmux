import CmuxSettings
import CmuxSidebarGit

extension TabManager {
    func applyAutoWorkspaceColorIfNeeded(
        to newWorkspace: Workspace,
        workingDirectory: String?
    ) {
        guard newWorkspace.customColor == nil,
              shouldAutoColorWorkspaceFromCwd else {
            return
        }
        let directory = workingDirectory ?? newWorkspace.currentDirectory
        // Resolving the seed walks the filesystem to the Git root and reads
        // `.git/config`. Route it through the shared workspace git probe limiter
        // so a burst of workspace creations (e.g. session restore) cannot fan
        // out into one unbounded blocking scan per workspace; the sidebar git
        // metadata path uses the same bounded permit pool.
        let probeLimiter = workspaceGitProbeLimiter
        Task.detached(priority: .utility) { [weak self, weak newWorkspace, directory] in
            guard await probeLimiter.acquire() else { return }
            defer {
                Task {
                    await probeLimiter.release()
                }
            }

            guard !Task.isCancelled,
                  let color = WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: directory) else {
                return
            }
            await MainActor.run { [weak self, weak newWorkspace] in
                guard let self,
                      let newWorkspace,
                      newWorkspace.owningTabManager === self,
                      newWorkspace.customColor == nil else {
                    return
                }
                newWorkspace.setCustomColor(color)
            }
        }
    }
}
