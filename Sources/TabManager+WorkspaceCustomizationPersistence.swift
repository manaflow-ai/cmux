import CmuxWorkspaces
import Foundation

extension TabManager {
    /// Migrates v1 directory records only when one restored workspace owns the directory.
    func prepareLegacyWorkspaceCustomizationMigration(
        afterRestoring snapshots: [SessionWorkspaceSnapshot]
    ) {
        var candidatesByDirectory: [String: [UUID?]] = [:]
        for snapshot in snapshots {
            guard let directory = legacyWorkspaceCustomizationDirectory(
                afterRestoring: snapshot
            ) else {
                continue
            }
            candidatesByDirectory[directory, default: []].append(snapshot.stableId)
        }

        var uniqueStableIdsByDirectory: [String: UUID] = [:]
        for (directory, candidates) in candidatesByDirectory {
            guard candidates.count == 1,
                  let stableId = candidates[0] else {
                continue
            }
            uniqueStableIdsByDirectory[directory] = stableId
        }
        workspaceCustomizationStore.migrateLegacyDirectoryCustomizations(
            toStableIdsByDirectory: uniqueStableIdsByDirectory
        )
    }

    /// Reads recovery records needed by one restore with a single defaults decode.
    func cachedWorkspaceCustomizations(
        afterRestoring snapshots: [SessionWorkspaceSnapshot]
    ) -> [UUID: WorkspaceCustomization] {
        workspaceCustomizationStore.customizations(
            for: snapshots.compactMap(\.stableId)
        )
    }

    /// Applies an explicit creation title without coupling identity to a directory.
    func applyCreationWorkspaceCustomization(
        to workspace: Workspace,
        explicitTitle: String?,
        explicitTitleSource: Workspace.CustomTitleSource
    ) {
        guard let explicitTitle else { return }
        workspace.setCustomTitle(explicitTitle, source: explicitTitleSource)
        recordWorkspaceCustomTitle(workspace, source: explicitTitleSource)
    }

    /// Applies stable-ID recovery data after the snapshot has restored its own identity.
    func reconcileWorkspaceCustomization(
        afterRestoring snapshot: SessionWorkspaceSnapshot,
        to workspace: Workspace
    ) {
        guard let stableId = snapshot.stableId,
              workspace.stableId == stableId,
              let stored = workspaceCustomizationStore.customization(for: stableId) else {
            return
        }
        applyWorkspaceCustomization(stored, to: workspace)
    }

    /// Applies one cached stable-ID recovery record.
    func reconcileWorkspaceCustomization(
        afterRestoring snapshot: SessionWorkspaceSnapshot,
        to workspace: Workspace,
        cachedCustomizations: [UUID: WorkspaceCustomization]
    ) {
        guard let stableId = snapshot.stableId,
              workspace.stableId == stableId,
              let stored = cachedCustomizations[stableId] else {
            return
        }
        applyWorkspaceCustomization(stored, to: workspace)
    }

    func recordWorkspaceCustomTitle(
        _ workspace: Workspace,
        source: Workspace.CustomTitleSource
    ) {
        guard source == .user else { return }
        workspaceCustomizationStore.setCustomTitle(
            workspace.customTitle,
            for: workspace.stableId
        )
    }

    func applyWorkspaceColor(_ color: String?, to workspaces: [Workspace]) {
        guard !workspaces.isEmpty else { return }
        for workspace in workspaces {
            workspace.setCustomColor(color)
        }
        workspaceCustomizationStore.setCustomColor(
            workspaces.first?.customColor,
            for: workspaces.map(\.stableId)
        )
    }

    private func applyWorkspaceCustomization(
        _ customization: WorkspaceCustomization,
        to workspace: Workspace
    ) {
        switch customization.customTitle {
        case .absent:
            break
        case let .value(title):
            workspace.setCustomTitle(title)
        case .cleared:
            // A prior user clear re-enables auto-naming; it must not evict
            // a subsequently auto-derived title restored from the session
            // snapshot. Without this guard, the durable customization journal
            // clobbers the snapshot's `.auto` title on every restore, so
            // auto-named workspaces lose their title across restart until the
            // next turn re-derives it.
            if workspace.effectiveCustomTitleSource != .auto {
                workspace.setCustomTitle(nil)
            }
        }

        switch customization.customColor {
        case .absent:
            break
        case let .value(color):
            workspace.setCustomColor(color)
        case .cleared:
            workspace.setCustomColor(nil)
        }
    }

    private func legacyWorkspaceCustomizationDirectory(
        afterRestoring snapshot: SessionWorkspaceSnapshot
    ) -> String? {
        if snapshot.usesWorkspaceDirectoryCustomization == false {
            return nil
        }
        if let directory = snapshot.customizationDirectory {
            return workspaceCustomizationStore.legacyDirectoryKey(for: directory)
        }
        guard snapshot.usesWorkspaceDirectoryCustomization == nil,
              snapshot.remote == nil,
              (snapshot.currentDirectory as NSString).isAbsolutePath else {
            return nil
        }
        return workspaceCustomizationStore.legacyDirectoryKey(
            for: snapshot.currentDirectory
        )
    }
}
