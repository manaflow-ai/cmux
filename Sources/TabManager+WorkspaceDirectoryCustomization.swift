import Foundation

extension TabManager {
    /// Applies sticky identity to a newly-created workspace. An explicit creation title wins.
    func applyWorkspaceDirectoryCustomization(
        to workspace: Workspace,
        explicitTitle: String?
    ) {
        let directoryKey = workspaceDirectoryCustomizationStore.directoryKey(
            for: workspace.currentDirectory
        )
        workspace.customizationDirectory = directoryKey

        if let customization = workspaceDirectoryCustomizationStore.customization(
            for: directoryKey
        ) {
            if explicitTitle == nil, let customTitle = customization.customTitle {
                workspace.setCustomTitle(customTitle)
            }
            if let customColor = customization.customColor {
                workspace.setCustomColor(customColor)
            }
        }

        if let explicitTitle {
            workspace.setCustomTitle(explicitTitle)
            recordWorkspaceCustomTitle(workspace, source: .user)
        }
    }

    /// Merges a restored snapshot with sticky identity, preferring explicit user data in the snapshot.
    func reconcileWorkspaceDirectoryCustomization(
        afterRestoring snapshot: SessionWorkspaceSnapshot,
        to workspace: Workspace
    ) {
        let directory = snapshot.customizationDirectory ?? snapshot.currentDirectory
        guard let directoryKey = workspaceDirectoryCustomizationStore.directoryKey(for: directory) else {
            return
        }
        workspace.customizationDirectory = directoryKey
        let stored = workspaceDirectoryCustomizationStore.customization(for: directoryKey)

        let snapshotTitleIsUserOwned = snapshot.customTitle != nil
            && (snapshot.customTitleSource ?? .user) == .user
        if snapshotTitleIsUserOwned {
            workspaceDirectoryCustomizationStore.setCustomTitle(
                workspace.customTitle,
                for: directoryKey
            )
        } else if let storedTitle = stored?.customTitle {
            workspace.setCustomTitle(storedTitle)
        }

        if snapshot.customColor != nil {
            workspaceDirectoryCustomizationStore.setCustomColor(
                workspace.customColor,
                for: directoryKey
            )
        } else if let storedColor = stored?.customColor {
            workspace.setCustomColor(storedColor)
        }
    }

    func recordWorkspaceCustomTitle(
        _ workspace: Workspace,
        source: Workspace.CustomTitleSource
    ) {
        guard source == .user,
              let directory = customizationDirectory(for: workspace) else {
            return
        }
        workspaceDirectoryCustomizationStore.setCustomTitle(
            workspace.customTitle,
            for: directory
        )
    }

    func recordWorkspaceCustomColor(_ workspace: Workspace) {
        guard let directory = customizationDirectory(for: workspace) else { return }
        workspaceDirectoryCustomizationStore.setCustomColor(
            workspace.customColor,
            for: directory
        )
    }

    private func customizationDirectory(for workspace: Workspace) -> String? {
        if let existing = workspaceDirectoryCustomizationStore.directoryKey(
            for: workspace.customizationDirectory
        ) {
            return existing
        }
        guard let current = workspaceDirectoryCustomizationStore.directoryKey(
            for: workspace.currentDirectory
        ) else {
            return nil
        }
        workspace.customizationDirectory = current
        return current
    }
}
