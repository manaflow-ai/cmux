import CmuxWorkspaces
import Foundation

extension TabManager {
    /// Gives automatic title persistence a short coalescing window. Process
    /// title notifications can arrive for every shell command, and each store
    /// write encodes the complete recovery snapshot synchronously on the main
    /// actor. A fixed window bounds durability lag while collapsing bursts.
    private static let automaticWorkspaceTitlePersistenceDelay: Duration = .milliseconds(250)

    /// Flushes all queued automatic title records. Lifecycle code calls this
    /// before termination, while tests and restore boundaries can use it to
    /// make the durability point explicit.
    func flushPendingWorkspaceCustomizationWrites() {
        automaticWorkspaceTitlePersistenceTask?.cancel()
        automaticWorkspaceTitlePersistenceTask = nil
        guard !pendingAutomaticWorkspaceTitles.isEmpty else { return }
        let pending = pendingAutomaticWorkspaceTitles
        pendingAutomaticWorkspaceTitles.removeAll(keepingCapacity: true)
        workspaceCustomizationStore.persistPendingAutomaticTitlesSynchronously(
            pending.map { stableId, pendingTitle in
                WorkspaceCustomizationPendingAutomaticTitle(
                    stableId: stableId,
                    title: pendingTitle.title,
                    titleMutationRevision: pendingTitle.titleMutationRevision,
                    automaticTitleOrdering: pendingTitle.automaticTitleOrdering
                )
            }
        )
    }

    private func scheduleAutomaticWorkspaceTitlePersistence() {
        guard automaticWorkspaceTitlePersistenceTask == nil else { return }
        automaticWorkspaceTitlePersistenceTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(
                    for: Self.automaticWorkspaceTitlePersistenceDelay
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushPendingWorkspaceCustomizationWrites()
        }
    }

    private func cancelPendingAutomaticWorkspaceTitle(for stableId: UUID) {
        pendingAutomaticWorkspaceTitles.removeValue(forKey: stableId)
        if pendingAutomaticWorkspaceTitles.isEmpty {
            automaticWorkspaceTitlePersistenceTask?.cancel()
            automaticWorkspaceTitlePersistenceTask = nil
        }
    }

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
        // Automatic naming normally belongs to the session snapshot. Once an
        // explicit clear has made auto-naming authoritative, journal each
        // subsequent automatic value so a stale snapshot cannot roll the title
        // back to an earlier refresh.
        if source == .auto {
            guard let record = workspaceCustomizationStore
                .customizationAndTitleMutationRevision(for: workspace.stableId) else {
                return
            }
            let field = record.customization.customTitle
            switch field {
            case .cleared, .autoValue:
                break
            case .absent, .value:
                return
            }
            let pending = pendingAutomaticWorkspaceTitles[workspace.stableId]
            let automaticTitleOrdering: UInt64
            if let pending {
                automaticTitleOrdering = pending.automaticTitleOrdering
            } else {
                Self.nextAutomaticWorkspaceTitleOrdering &+= 1
                automaticTitleOrdering = Self.nextAutomaticWorkspaceTitleOrdering
            }
            pendingAutomaticWorkspaceTitles[workspace.stableId] =
                PendingAutomaticWorkspaceTitle(
                    title: workspace.customTitle,
                    titleMutationRevision: pending?.titleMutationRevision
                        ?? record.titleMutationRevision,
                    automaticTitleOrdering: automaticTitleOrdering
                )
            scheduleAutomaticWorkspaceTitlePersistence()
            return
        }
        cancelPendingAutomaticWorkspaceTitle(for: workspace.stableId)
        workspaceCustomizationStore.setCustomTitle(
            workspace.customTitle,
            for: workspace.stableId,
            source: source == .auto ? .auto : .user
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
            workspace.setCustomTitle(title, source: .user)
        case let .autoValue(title):
            // The journal is newer than the session snapshot. Clear any stale
            // snapshot title before restoring the latest automatic value.
            workspace.setCustomTitle(nil)
            workspace.setCustomTitle(title, source: .auto)
        case .cleared:
            workspace.setCustomTitle(nil)
        }

        switch customization.customColor {
        case .absent:
            break
        case let .value(color):
            workspace.setCustomColor(color)
        case .autoValue:
            // Automatic provenance is valid only for titles. Ignore malformed
            // color records rather than treating them as a user color.
            break
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
