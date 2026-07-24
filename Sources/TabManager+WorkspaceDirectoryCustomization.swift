import Foundation

extension TabManager {
    /// Applies sticky identity to a newly-created workspace. An explicit creation title wins.
    func applyWorkspaceDirectoryCustomization(
        to workspace: Workspace,
        explicitTitle: String?,
        explicitTitleSource: Workspace.CustomTitleSource
    ) {
        let directoryKey = workspaceDirectoryCustomizationStore.directoryKey(
            for: workspace.currentDirectory
        )
        workspace.customizationDirectory = directoryKey

        if let customization = workspaceDirectoryCustomizationStore.customization(
            for: directoryKey
        ) {
            if (explicitTitle == nil || explicitTitleSource == .auto),
               let customTitle = customization.customTitle {
                workspace.setCustomTitle(customTitle)
            }
            if let customColor = customization.customColor {
                workspace.setCustomColor(customColor)
            }
        }

        if let explicitTitle {
            workspace.setCustomTitle(explicitTitle, source: explicitTitleSource)
            recordWorkspaceCustomTitle(workspace, source: explicitTitleSource)
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

        let snapshotTitleIsUserOwned = snapshot.customTitle != nil
            && (snapshot.customTitleSource ?? .user) == .user
        let snapshotOverridesStored = snapshotTitleIsUserOwned || snapshot.customColor != nil
        let resolved = if snapshotOverridesStored {
            workspaceDirectoryCustomizationStore.updateCustomization(for: directoryKey) { stored in
                WorkspaceDirectoryCustomization(
                    customTitle: snapshotTitleIsUserOwned
                        ? workspace.customTitle
                        : stored?.customTitle,
                    customColor: snapshot.customColor != nil
                        ? workspace.customColor
                        : stored?.customColor
                )
            }
        } else {
            workspaceDirectoryCustomizationStore.customization(for: directoryKey)
        }

        if !snapshotTitleIsUserOwned, let storedTitle = resolved?.customTitle {
            workspace.setCustomTitle(storedTitle)
        }

        if snapshot.customColor == nil, let storedColor = resolved?.customColor {
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

    func applyWorkspaceColor(_ color: String?, to workspaces: [Workspace]) {
        guard !workspaces.isEmpty else { return }
        for workspace in workspaces {
            workspace.setCustomColor(color)
        }
        let directories = workspaces.compactMap { customizationDirectory(for: $0) }
        workspaceDirectoryCustomizationStore.setCustomColor(
            workspaces.first?.customColor,
            forDirectories: directories
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
