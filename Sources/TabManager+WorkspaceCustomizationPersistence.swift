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
        for stableId in pending.keys {
            automaticWorkspaceTitleJournalState.removeValue(forKey: stableId)
        }
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
        // The delayed task may resume on any executor after its clock wait.
        // Keep every access to TabManager's queued state on its owning actor.
        automaticWorkspaceTitlePersistenceTask = Task { @MainActor [weak self] in
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
              let storedState = workspaceCustomizationStore
                  .customizationAndTitleMutationRevision(for: stableId) else {
            return
        }
        let shouldApplyTitle = shouldApplyWorkspaceTitle(
            storedState.customization,
            to: snapshot,
            titleMutationRevision: storedState.titleMutationRevision
        )
        applyWorkspaceCustomization(
            storedState.customization,
            to: workspace,
            applyTitle: shouldApplyTitle
        )
    }

    /// Applies one cached stable-ID recovery record.
    func reconcileWorkspaceCustomization(
        afterRestoring snapshot: SessionWorkspaceSnapshot,
        to workspace: Workspace,
        cachedCustomizations: [UUID: WorkspaceCustomization],
        cachedTitleMutationRevisions: [UUID: UInt64] = [:]
    ) {
        guard let stableId = snapshot.stableId,
              workspace.stableId == stableId,
              let stored = cachedCustomizations[stableId] else {
            return
        }
        let shouldApplyTitle = shouldApplyWorkspaceTitle(
            stored,
            to: snapshot,
            titleMutationRevision: cachedTitleMutationRevisions[stableId]
        )
        applyWorkspaceCustomization(stored, to: workspace, applyTitle: shouldApplyTitle)
    }

    /// Returns whether the journal title may replace the snapshot title.
    ///
    /// The title fence does not govern other customization fields. A stale or
    /// equal automatic title must not prevent an independent color recovery.
    private func shouldApplyWorkspaceTitle(
        _ customization: WorkspaceCustomization,
        to snapshot: SessionWorkspaceSnapshot,
        titleMutationRevision: UInt64?
    ) -> Bool {
        guard snapshot.customTitleSource == .auto,
              let snapshotRevision = snapshot.customTitleMutationRevision,
              let titleMutationRevision else {
            // User records and legacy snapshots retain the established journal
            // precedence. The fence is only comparable for provenance-aware
            // automatic titles written by the new schema.
            return true
        }
        switch customization.customTitle {
        case .autoValue, .cleared:
            return titleMutationRevision > snapshotRevision
        case .absent, .value:
            return true
        }
    }

    /// Pairs a session snapshot with the immutable journal state captured for
    /// the same stable identity. A live workspace can lag another manager's
    /// durable title, so the journal remains the source of truth unless a
    /// queued local automatic write is newer and still pending.
    func reconcileWorkspaceSnapshotCustomization(
        _ snapshot: inout SessionWorkspaceSnapshot,
        persistedCustomization: WorkspaceCustomization?,
        persistedTitleMutationRevision: UInt64?,
        pendingAutomaticTitle: PendingAutomaticWorkspaceTitle?
    ) {
        if let pendingAutomaticTitle {
            switch pendingAutomaticTitle.title {
            case let title?:
                guard snapshot.customTitleSource != .user else { break }
                snapshot.customTitle = title
                snapshot.customTitleSource = .auto
                snapshot.customTitleMutationRevision =
                    pendingAutomaticTitle.titleMutationRevision
                return
            case nil:
                guard snapshot.customTitleSource != .user else { break }
                snapshot.customTitle = nil
                snapshot.customTitleSource = nil
                snapshot.customTitleMutationRevision =
                    pendingAutomaticTitle.titleMutationRevision
                return
            }
        }

        guard let persistedCustomization,
              let persistedTitleMutationRevision else {
            return
        }
        switch persistedCustomization.customTitle {
        case .absent:
            break
        case let .value(title):
            snapshot.customTitle = title
            snapshot.customTitleSource = .user
            snapshot.customTitleMutationRevision = persistedTitleMutationRevision
        case let .autoValue(title):
            guard snapshot.customTitleSource != .user else { return }
            snapshot.customTitle = title
            snapshot.customTitleSource = .auto
            snapshot.customTitleMutationRevision = persistedTitleMutationRevision
        case .cleared:
            snapshot.customTitle = nil
            snapshot.customTitleSource = nil
            snapshot.customTitleMutationRevision = persistedTitleMutationRevision
        }
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
            let stableId = workspace.stableId
            let generation = workspaceCustomizationStore.changeGeneration()
            let state: (
                generation: UInt64,
                titleMutationRevision: UInt64,
                automaticTitleAllowed: Bool
            )
            if let cached = automaticWorkspaceTitleJournalState[stableId],
               cached.generation == generation {
                state = cached
            } else {
                let loaded = workspaceCustomizationStore
                    .customizationAndTitleMutationRevision(for: stableId)
                let automaticTitleAllowed = loaded.map { record in
                    switch record.customization.customTitle {
                    case .cleared, .autoValue:
                        return true
                    case .absent, .value:
                        return false
                    }
                } ?? false
                state = (
                    generation: generation,
                    titleMutationRevision: loaded?.titleMutationRevision ?? 0,
                    automaticTitleAllowed: automaticTitleAllowed
                )
                automaticWorkspaceTitleJournalState[stableId] = state
            }
            // Automatic title owners can clear a restored title before this
            // workspace has ever written a stable-ID record. Keep that clear
            // as a durable tombstone so a stale session snapshot cannot
            // resurrect the title on restart.
            let automaticTitleClear =
                workspace.customTitle == nil && workspace.customTitleSource == nil
            guard state.automaticTitleAllowed || automaticTitleClear else { return }
            // Every notification is a new observation. A different manager
            // may have persisted a newer automatic title since this manager
            // queued its previous value, so retaining the pending fence
            // would make the newest value look stale and drop it.
            Self.nextAutomaticWorkspaceTitleOrdering &+= 1
            let automaticTitleOrdering = Self.nextAutomaticWorkspaceTitleOrdering
            pendingAutomaticWorkspaceTitles[workspace.stableId] =
                PendingAutomaticWorkspaceTitle(
                    title: workspace.customTitle,
                    titleMutationRevision: state.titleMutationRevision,
                    automaticTitleOrdering: automaticTitleOrdering
                )
            scheduleAutomaticWorkspaceTitlePersistence()
            return
        }
        cancelPendingAutomaticWorkspaceTitle(for: workspace.stableId)
        automaticWorkspaceTitleJournalState.removeValue(forKey: workspace.stableId)
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
        to workspace: Workspace,
        applyTitle: Bool = true
    ) {
        if applyTitle {
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
