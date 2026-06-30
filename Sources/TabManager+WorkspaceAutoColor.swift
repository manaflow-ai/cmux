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
        newWorkspace.autoColorProbeTask = Task.detached(priority: .utility) { [weak self, weak newWorkspace, directory] in
            // Don't queue for a permit if the workspace/window is already gone.
            guard self != nil, newWorkspace != nil else { return }
            guard await probeLimiter.acquire() else { return }
            defer {
                Task {
                    await probeLimiter.release()
                }
            }

            // The permit can be contended, so re-check before the filesystem
            // scan: skip workspaces closed, re-parented, or already colored
            // while this task waited in the limiter queue.
            guard !Task.isCancelled,
                  await TabManager.canAutoColorWorkspace(self, newWorkspace),
                  let color = WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: directory) else {
                return
            }
            await MainActor.run { [weak self, weak newWorkspace] in
                guard let newWorkspace,
                      TabManager.canAutoColorWorkspace(self, newWorkspace) else {
                    return
                }
                newWorkspace.setCustomColor(color)
            }
        }
    }

    /// Whether `workspace` is still owned by `manager` and has no color yet, so
    /// an in-flight auto-color probe should keep going. Run on the main actor
    /// because workspace ownership and color are main-actor state.
    @MainActor
    private static func canAutoColorWorkspace(
        _ manager: TabManager?,
        _ workspace: Workspace?
    ) -> Bool {
        guard let manager,
              let workspace,
              workspace.owningTabManager === manager,
              workspace.customColor == nil else {
            return false
        }
        return true
    }
}
