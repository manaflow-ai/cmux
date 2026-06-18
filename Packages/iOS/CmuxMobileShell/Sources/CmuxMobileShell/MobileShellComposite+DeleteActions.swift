internal import CmuxMobileRPC
public import CmuxMobileShellModel
internal import CmuxMobileSupport
internal import Foundation
internal import OSLog

private let mobileShellDeleteLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell-delete"
)

@MainActor
extension MobileShellComposite {
    /// Close a workspace through the Mac's existing workspace-close path.
    ///
    /// The phone removes the row locally and moves selection to the same-order
    /// neighbor before the remote mutation completes, so a full-swipe delete
    /// feels committed immediately. If the close RPC fails, the removed row is
    /// restored and selection rolls back; after success, the authoritative
    /// workspace list refresh reconciles the final Mac state.
    public func deleteWorkspace(id: MobileWorkspacePreview.ID) {
        guard workspaces.count > 1,
              let deletedWorkspaceIndex = workspaces.firstIndex(where: { $0.id == id }) else {
            return
        }
        let deletedWorkspace = workspaces[deletedWorkspaceIndex]
        let deletedAttachments = pendingAttachmentSnapshot(for: deletedWorkspace)
        let previousWorkspaceID = selectedWorkspaceID
        let previousTerminalID = selectedTerminalID
        let neighborID = neighboringWorkspaceID(afterDeleting: id)
        let usesRemoteClient = remoteClient != nil
        deleteLocalWorkspace(id: id, neighborID: neighborID)

        guard usesRemoteClient else { return }

        enqueueDeleteMutation(
            onSkipped: { [weak self] in
                guard let self else { return }
                restoreLocalWorkspace(deletedWorkspace, at: deletedWorkspaceIndex)
                restorePendingAttachments(deletedAttachments)
                restoreSelection(
                    workspaceID: previousWorkspaceID,
                    terminalID: previousTerminalID
                )
            }
        ) { [weak self] in
            await self?.deleteRemoteWorkspace(
                id: id,
                deletedWorkspace: deletedWorkspace,
                deletedWorkspaceIndex: deletedWorkspaceIndex,
                deletedAttachments: deletedAttachments,
                previousWorkspaceID: previousWorkspaceID,
                previousTerminalID: previousTerminalID
            )
        }
    }

    /// Close a terminal surface through the Mac's existing surface/workspace
    /// close paths. If the surface is the last terminal in the workspace, the
    /// Mac decides whether the containing workspace still has non-terminal panels
    /// or must close too; the refreshed remote list reconciles that final state.
    public func deleteTerminal(
        id terminalID: MobileTerminalPreview.ID,
        in workspaceID: MobileWorkspacePreview.ID
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.terminals.contains(where: { $0.id == terminalID }) else {
            return
        }
        let removesLastKnownTerminal = workspace.terminals.count <= 1
        let usesRemoteClient = remoteClient != nil
        guard usesRemoteClient || !removesLastKnownTerminal || workspaces.count > 1 else {
            return
        }
        let previousWorkspaceID = selectedWorkspaceID
        let previousTerminalID = selectedTerminalID
        let deletedWorkspace = workspace
        let deletedWorkspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) ?? 0
        guard let deletedTerminalIndex = workspace.terminals.firstIndex(where: { $0.id == terminalID }) else {
            return
        }
        let deletedTerminal = workspace.terminals[deletedTerminalIndex]
        let deletedAttachments = pendingAttachmentSnapshot(forTerminalID: terminalID)
        deleteLocalTerminal(id: terminalID, in: workspaceID)

        guard usesRemoteClient else { return }

        enqueueDeleteMutation(
            onSkipped: { [weak self] in
                guard let self else { return }
                restoreLocalTerminal(
                    deletedTerminal,
                    in: workspaceID,
                    at: deletedTerminalIndex,
                    deletedWorkspace: deletedWorkspace,
                    deletedWorkspaceIndex: deletedWorkspaceIndex
                )
                restorePendingAttachments(deletedAttachments)
                restoreSelection(
                    workspaceID: previousWorkspaceID,
                    terminalID: previousTerminalID
                )
            }
        ) { [weak self] in
            await self?.deleteRemoteTerminal(
                id: terminalID,
                in: workspaceID,
                deletedWorkspace: deletedWorkspace,
                deletedWorkspaceIndex: deletedWorkspaceIndex,
                deletedTerminal: deletedTerminal,
                deletedTerminalIndex: deletedTerminalIndex,
                deletedAttachments: deletedAttachments,
                previousWorkspaceID: previousWorkspaceID,
                previousTerminalID: previousTerminalID
            )
        }
    }

    func rollbackPendingDeleteMutations() {
        let rollbacks = pendingDeleteRollbackHandlers.map { $0.rollback }
        pendingDeleteRollbackHandlers.removeAll()
        for rollback in rollbacks.reversed() {
            rollback()
        }
    }

    @discardableResult
    private func enqueueDeleteMutation(
        onSkipped: @escaping @MainActor @Sendable () -> Void,
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = deleteMutationTask, taskID = UUID(), generation = connectionGeneration
        deleteMutationTaskID = taskID
        pendingDeleteRollbackHandlers.append((id: taskID, rollback: onSkipped))
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer { self.clearDeleteMutationTask(id: taskID) }
            guard connectionGeneration == generation, !Task.isCancelled else {
                rollbackPendingDeleteMutation(id: taskID)
                return
            }
            removePendingDeleteRollback(id: taskID)
            await operation()
        }
        deleteMutationTask = task
        return task
    }

    private func removePendingDeleteRollback(id: UUID) {
        pendingDeleteRollbackHandlers.removeAll { $0.id == id }
    }

    private func rollbackPendingDeleteMutation(id: UUID) {
        guard let index = pendingDeleteRollbackHandlers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let rollback = pendingDeleteRollbackHandlers.remove(at: index).rollback
        rollback()
    }

    private func clearDeleteMutationTask(id: UUID) {
        guard deleteMutationTaskID == id else { return }
        deleteMutationTask = nil
        deleteMutationTaskID = nil
    }

    private func deleteRemoteWorkspace(
        id: MobileWorkspacePreview.ID,
        deletedWorkspace: MobileWorkspacePreview,
        deletedWorkspaceIndex: Int,
        deletedAttachments: [String: [MobilePendingAttachment]],
        previousWorkspaceID: MobileWorkspacePreview.ID?,
        previousTerminalID: MobileTerminalPreview.ID?
    ) async {
        guard let client = remoteClient else { return }
        let generation = connectionGeneration
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "workspace.close",
                params: [
                    "workspace_id": id.rawValue,
                    "client_id": clientID,
                ]
            )
            _ = try await client.sendRequest(request)
            guard isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
        } catch {
            handleRemoteDeleteError(
                error,
                generation: generation,
                rollback: {
                    restoreLocalWorkspace(deletedWorkspace, at: deletedWorkspaceIndex)
                    restorePendingAttachments(deletedAttachments)
                },
                previousWorkspaceID: previousWorkspaceID,
                previousTerminalID: previousTerminalID
            )
            return
        }
        await refreshRemoteWorkspaceListAfterSuccessfulMutation(client: client, generation: generation)
    }

    private func deleteRemoteTerminal(
        id terminalID: MobileTerminalPreview.ID,
        in workspaceID: MobileWorkspacePreview.ID,
        deletedWorkspace: MobileWorkspacePreview,
        deletedWorkspaceIndex: Int,
        deletedTerminal: MobileTerminalPreview,
        deletedTerminalIndex: Int,
        deletedAttachments: [String: [MobilePendingAttachment]],
        previousWorkspaceID: MobileWorkspacePreview.ID?,
        previousTerminalID: MobileTerminalPreview.ID?
    ) async {
        guard let client = remoteClient else { return }
        let generation = connectionGeneration
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "surface.close",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": terminalID.rawValue,
                    "client_id": clientID,
                ]
            )
            _ = try await client.sendRequest(request)
            guard isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
        } catch {
            handleRemoteDeleteError(
                error,
                generation: generation,
                rollback: {
                    restoreLocalTerminal(
                        deletedTerminal,
                        in: workspaceID,
                        at: deletedTerminalIndex,
                        deletedWorkspace: deletedWorkspace,
                        deletedWorkspaceIndex: deletedWorkspaceIndex
                    )
                    restorePendingAttachments(deletedAttachments)
                },
                previousWorkspaceID: previousWorkspaceID,
                previousTerminalID: previousTerminalID
            )
            return
        }
        await refreshRemoteWorkspaceListAfterSuccessfulMutation(client: client, generation: generation)
    }

    private func refreshRemoteWorkspaceListAfterSuccessfulMutation(
        client: MobileCoreRPCClient,
        generation: UUID
    ) async {
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.workspace.list", params: [:])
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteOperation(client: client, generation: generation),
                  !Task.isCancelled else { return }
            applyRemoteWorkspaceList(response)
        } catch {
            guard isCurrentRemoteConnection(client: client, generation: generation),
                  !Task.isCancelled else { return }
            if disconnectForAuthorizationFailureIfNeeded(error) { return }
            markMacConnectionUnavailableIfNeeded(after: error)
            mobileShellDeleteLog.info("workspace list refresh after remote delete failed: \(String(describing: error), privacy: .private)")
        }
    }

    private func handleRemoteDeleteError(
        _ error: any Error,
        generation: UUID,
        rollback: () -> Void,
        previousWorkspaceID: MobileWorkspacePreview.ID?,
        previousTerminalID: MobileTerminalPreview.ID?
    ) {
        guard generation == connectionGeneration, !Task.isCancelled else { return }
        rollback()
        restoreSelection(
            workspaceID: previousWorkspaceID,
            terminalID: previousTerminalID
        )
        guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
        markMacConnectionUnavailableIfNeeded(after: error)
        applyDeleteError(
            message: Self.localizedDeleteError(),
            guidance: Self.localizedDeleteErrorGuidance()
        )
    }

    /// Headline shown when a remote delete (workspace or surface) fails after
    /// the optimistic removal has been reverted by ``restoreSelection``.
    private static func localizedDeleteError() -> String {
        L10n.string(
            "mobile.delete.failed.message",
            defaultValue: "Couldn't delete that on your Mac."
        )
    }

    /// Actionable next-step line shown beneath ``localizedDeleteError`` so the
    /// user knows the item is still there and why.
    private static func localizedDeleteErrorGuidance() -> String {
        L10n.string(
            "mobile.delete.failed.guidance",
            defaultValue: "Check your connection to your Mac and try again."
        )
    }

    private func restoreSelection(
        workspaceID: MobileWorkspacePreview.ID?,
        terminalID: MobileTerminalPreview.ID?
    ) {
        if let workspaceID,
           workspaces.contains(where: { $0.id == workspaceID }) {
            setSelectedWorkspaceID(workspaceID)
        } else if workspaceID == nil {
            setSelectedWorkspaceID(nil)
        } else if selectedWorkspace == nil {
            setSelectedWorkspaceID(workspaces.first?.id)
        }

        guard let selectedWorkspace else {
            selectedTerminalID = nil
            return
        }
        if let terminalID,
           selectedWorkspace.terminals.contains(where: { $0.id == terminalID }) {
            selectedTerminalID = terminalID
        } else {
            syncSelectedTerminalForWorkspace()
        }
    }

    private func restoreLocalWorkspace(
        _ workspace: MobileWorkspacePreview,
        at index: Int
    ) {
        guard !workspaces.contains(where: { $0.id == workspace.id }) else {
            return
        }
        workspaces.insert(workspace, at: min(index, workspaces.count))
    }

    private func pendingAttachmentSnapshot(
        for workspace: MobileWorkspacePreview
    ) -> [String: [MobilePendingAttachment]] {
        let terminalIDs = Set(workspace.terminals.map(\.id.rawValue))
        return pendingAttachmentsByTerminalID.filter { terminalIDs.contains($0.key) }
    }

    private func pendingAttachmentSnapshot(
        forTerminalID terminalID: MobileTerminalPreview.ID
    ) -> [String: [MobilePendingAttachment]] {
        let key = terminalID.rawValue
        guard let attachments = pendingAttachmentsByTerminalID[key] else { return [:] }
        return [key: attachments]
    }

    private func restorePendingAttachments(
        _ snapshot: [String: [MobilePendingAttachment]]
    ) {
        for (terminalID, attachments) in snapshot {
            pendingAttachmentsByTerminalID[terminalID] = attachments
        }
    }

    private func restoreLocalTerminal(
        _ terminal: MobileTerminalPreview,
        in workspaceID: MobileWorkspacePreview.ID,
        at terminalIndex: Int,
        deletedWorkspace: MobileWorkspacePreview,
        deletedWorkspaceIndex: Int
    ) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            restoreLocalWorkspace(deletedWorkspace, at: deletedWorkspaceIndex)
            return
        }
        guard !workspaces[workspaceIndex].terminals.contains(where: { $0.id == terminal.id }) else {
            return
        }
        workspaces[workspaceIndex].terminals.insert(
            terminal,
            at: min(terminalIndex, workspaces[workspaceIndex].terminals.count)
        )
    }

    private func deleteLocalWorkspace(
        id workspaceID: MobileWorkspacePreview.ID,
        neighborID: MobileWorkspacePreview.ID? = nil
    ) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces.count > 1 else {
            return
        }
        let fallbackNeighborID = neighborID ?? neighboringWorkspaceID(afterDeleting: workspaceID)
        workspaces.remove(at: index)
        let selectedWorkspaceStillExists = selectedWorkspaceID.map { selectedID in
            workspaces.contains { $0.id == selectedID }
        } ?? false
        if selectedWorkspaceID == workspaceID ||
            selectedWorkspaceID == nil ||
            !selectedWorkspaceStillExists {
            setSelectedWorkspaceID(fallbackNeighborID ?? workspaces.first?.id)
        }
    }

    private func deleteLocalTerminal(
        id terminalID: MobileTerminalPreview.ID,
        in workspaceID: MobileWorkspacePreview.ID
    ) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let terminalIndex = workspaces[workspaceIndex].terminals.firstIndex(where: { $0.id == terminalID }) else {
            return
        }
        guard workspaces[workspaceIndex].terminals.count > 1 else {
            deleteLocalWorkspace(id: workspaceID)
            return
        }

        let fallbackTerminalID = neighboringTerminalID(afterDeleting: terminalID, in: workspaceID)
        workspaces[workspaceIndex].terminals.remove(at: terminalIndex)
        terminalAutoFocusSuppressedSurfaceIDs.remove(terminalID.rawValue)
        let selectedTerminalStillExists = selectedTerminalID.map { selectedID in
            workspaces[workspaceIndex].terminals.contains { $0.id == selectedID }
        } ?? false
        if selectedWorkspaceID == workspaceID,
           (selectedTerminalID == terminalID ||
            selectedTerminalID == nil ||
            !selectedTerminalStillExists) {
            selectedTerminalID = fallbackTerminalID ?? workspaces[workspaceIndex].terminals.first?.id
        }
    }

    private func neighboringWorkspaceID(
        afterDeleting workspaceID: MobileWorkspacePreview.ID
    ) -> MobileWorkspacePreview.ID? {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return selectedWorkspaceID
        }
        guard workspaces.count > 1 else { return nil }
        let neighborIndex = index < workspaces.count - 1 ? index + 1 : index - 1
        return workspaces[neighborIndex].id
    }

    private func neighboringTerminalID(
        afterDeleting terminalID: MobileTerminalPreview.ID,
        in workspaceID: MobileWorkspacePreview.ID
    ) -> MobileTerminalPreview.ID? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              let index = workspace.terminals.firstIndex(where: { $0.id == terminalID }) else {
            return selectedTerminalID
        }
        guard workspace.terminals.count > 1 else { return nil }
        let neighborIndex = index < workspace.terminals.count - 1 ? index + 1 : index - 1
        return workspace.terminals[neighborIndex].id
    }
}
