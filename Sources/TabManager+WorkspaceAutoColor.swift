import CmuxSettings

extension TabManager {
    func applyAutoWorkspaceColorIfNeeded(
        to newWorkspace: Workspace,
        workingDirectory: String?
    ) {
        guard newWorkspace.customColor == nil,
              settings.value(for: settingsCatalog.workspaceColors.autoColorFromCwd) else {
            return
        }
        let directory = workingDirectory ?? newWorkspace.currentDirectory
        Task.detached(priority: .utility) { [weak self, weak newWorkspace, directory] in
            guard let color = WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: directory) else {
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
