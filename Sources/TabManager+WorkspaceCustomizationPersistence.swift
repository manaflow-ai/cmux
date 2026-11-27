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
        explicitTitleSource: Workspace.CustomTitleSource,
        repairInitialTabTitle: Bool = true
    ) {
        guard let explicitTitle else { return }
        workspace.setCustomTitle(explicitTitle, source: explicitTitleSource)
        recordWorkspaceCustomTitle(workspace, source: explicitTitleSource)
        if repairInitialTabTitle,
           let panelId = workspace.focusedPanelId,
           let surfaceId = workspace.surfaceIdFromPanelId(panelId) {
            // Workspace construction admits automatic titles before this
            // explicit custom-title path runs. Keep the initial Bonsplit tab
            // faithful to an authored creation name.
            workspace.bonsplitController.updateTab(surfaceId, title: explicitTitle)
        }
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
        applyWorkspaceCustomization(stored, afterRestoring: snapshot, to: workspace)
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
        applyWorkspaceCustomization(stored, afterRestoring: snapshot, to: workspace)
    }

    func recordWorkspaceCustomTitle(
        _ workspace: Workspace,
        source: Workspace.CustomTitleSource
    ) {
        guard let storedSource = WorkspaceCustomization.TitleSource(rawValue: source.rawValue) else { return }
        workspaceCustomizationStore.setCustomTitle(
            workspace.customTitle,
            source: storedSource,
            for: workspace.stableId
        )
    }

    func setTabColor(tabId: UUID, color: String?) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        applyWorkspaceColor(color, to: [tab])
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
        afterRestoring snapshot: SessionWorkspaceSnapshot,
        to workspace: Workspace
    ) {
        // Old journals never observed automatic or remote writes. Prefer the
        // snapshot for those titles; source-aware records track every landed
        // write and can recover even a rename newer than the snapshot.
        if customization.customTitleSource != nil ||
            snapshot.effectiveCustomTitleSource == nil ||
            snapshot.effectiveCustomTitleSource == .user {
            let source = customization.customTitleSource.flatMap {
                Workspace.CustomTitleSource(rawValue: $0.rawValue)
            } ?? .user
            switch customization.customTitle {
            case .absent:
                break
            case let .value(title):
                // The journal may contain an auto title after a user clear
                // that the older snapshot has not observed yet.
                if source == .auto {
                    workspace.setCustomTitle(nil)
                }
                workspace.setCustomTitle(title, source: source)
            case .cleared:
                workspace.setCustomTitle(nil, source: source)
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
