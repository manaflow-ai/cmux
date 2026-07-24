import Foundation

extension TabManager {
    /// Applies sticky identity to a newly-created workspace. A user-owned creation title wins.
    func applyWorkspaceDirectoryCustomization(
        to workspace: Workspace,
        rootDirectory: String?,
        explicitTitle: String?,
        explicitTitleSource: Workspace.CustomTitleSource
    ) {
        let directoryKey = workspaceDirectoryCustomizationStore.directoryKey(
            for: rootDirectory
        )
        guard let directoryKey else { return }
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

    /// Applies authoritative sticky identity, seeding it from a snapshot only for a new directory.
    func reconcileWorkspaceDirectoryCustomization(
        afterRestoring snapshot: SessionWorkspaceSnapshot,
        to workspace: Workspace
    ) {
        guard let directoryKey = workspaceDirectoryCustomizationStore.directoryKey(
            for: snapshot.customizationDirectory
        ) else {
            return
        }
        workspace.customizationDirectory = directoryKey

        if let stored = workspaceDirectoryCustomizationStore.customization(for: directoryKey) {
            workspace.setCustomTitle(stored.customTitle)
            workspace.setCustomColor(stored.customColor)
            return
        }

        let snapshotTitleIsUserOwned = snapshot.customTitle != nil
            && (snapshot.customTitleSource ?? .user) == .user
        guard snapshotTitleIsUserOwned || snapshot.customColor != nil else {
            return
        }
        workspaceDirectoryCustomizationStore.updateCustomization(for: directoryKey) { _ in
            WorkspaceDirectoryCustomization(
                customTitle: snapshotTitleIsUserOwned ? workspace.customTitle : nil,
                customColor: snapshot.customColor != nil ? workspace.customColor : nil
            )
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
        workspaceDirectoryCustomizationStore.directoryKey(
            for: workspace.customizationDirectory
        )
    }
}
