import CmuxSettings

extension TabManager {
    func applyAutoWorkspaceColorIfNeeded(
        to newWorkspace: Workspace,
        workingDirectory: String?
    ) {
        guard newWorkspace.customColor == nil,
              settings.value(for: settingsCatalog.workspaceColors.autoColorFromCwd),
              let color = WorkspaceTabColorSettings.autoColorHex(
                  forWorkingDirectory: workingDirectory ?? newWorkspace.currentDirectory
              ) else {
            return
        }
        newWorkspace.setCustomColor(color)
    }
}
