import CmuxWorkspaces
import Foundation

extension TabManager {
    /// Reads the sticky records needed by one session restore with a single defaults decode.
    func cachedWorkspaceDirectoryCustomizations(
        afterRestoring snapshots: [SessionWorkspaceSnapshot]
    ) -> [String: WorkspaceDirectoryCustomization] {
        workspaceDirectoryCustomizationStore.customizations(
            forDirectories: snapshots.compactMap(workspaceCustomizationDirectory(afterRestoring:))
        )
    }

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

    /// Resolves the sticky-customization root carried by a restored snapshot.
    func workspaceCustomizationDirectory(
        afterRestoring snapshot: SessionWorkspaceSnapshot
    ) -> String? {
        if snapshot.usesWorkspaceDirectoryCustomization == false {
            return nil
        }
        if let directory = snapshot.customizationDirectory {
            return workspaceDirectoryCustomizationStore.directoryKey(for: directory)
        }
        guard snapshot.usesWorkspaceDirectoryCustomization == nil,
              snapshot.remote == nil,
              (snapshot.currentDirectory as NSString).isAbsolutePath else {
            return nil
        }
        return workspaceDirectoryCustomizationStore.directoryKey(for: snapshot.currentDirectory)
    }

    /// Applies authoritative sticky identity, seeding it from a snapshot only for a new directory.
    func reconcileWorkspaceDirectoryCustomization(
        afterRestoring snapshot: SessionWorkspaceSnapshot,
        to workspace: Workspace
    ) {
        guard let directoryKey = workspaceCustomizationDirectory(afterRestoring: snapshot) else {
            return
        }
        var cachedCustomizations = workspaceDirectoryCustomizationStore.customizations(
            forDirectories: [directoryKey]
        )
        reconcileWorkspaceDirectoryCustomization(
            afterRestoring: snapshot,
            to: workspace,
            cachedCustomizations: &cachedCustomizations
        )
    }

    /// Reconciles one restored workspace against a shared per-restore customization cache.
    func reconcileWorkspaceDirectoryCustomization(
        afterRestoring snapshot: SessionWorkspaceSnapshot,
        to workspace: Workspace,
        cachedCustomizations: inout [String: WorkspaceDirectoryCustomization]
    ) {
        guard let directoryKey = workspaceCustomizationDirectory(afterRestoring: snapshot) else {
            return
        }
        workspace.customizationDirectory = directoryKey

        if let stored = cachedCustomizations[directoryKey] {
            workspace.setCustomTitle(stored.customTitle)
            workspace.setCustomColor(stored.customColor)
            return
        }

        let snapshotTitleIsUserOwned = snapshot.customTitle != nil
            && (snapshot.customTitleSource ?? .user) == .user
        guard snapshotTitleIsUserOwned || snapshot.customColor != nil else {
            return
        }
        let seeded = workspaceDirectoryCustomizationStore.updateCustomization(for: directoryKey) { _ in
            WorkspaceDirectoryCustomization(
                customTitle: snapshotTitleIsUserOwned ? workspace.customTitle : nil,
                customColor: snapshot.customColor != nil ? workspace.customColor : nil
            )
        }
        if let seeded {
            cachedCustomizations[directoryKey] = seeded
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
