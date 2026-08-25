#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

extension TaskComposerSheet {
    func selectTemplate(_ template: MobileTaskTemplate, modelID: String? = nil) {
        let validatedModelID = validatedModelID(modelID, for: template)
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedTemplateID = template.id
            selectedModelID = validatedModelID
            explicitlySelectedModel = nil
            selectedEffortID = nil
            if template.isPlainShell {
                removeStagedAttachmentFiles()
                attachments.removeAll()
            }
            syncSuggestedDirectory()
        }
        store.recordAppEvent(
            .taskProviderSelected,
            correlationID: template.id.uuidString
        )
    }

    func restoreSubmittedDraft(_ snapshot: MobileTaskSubmissionSnapshot) {
        prompt = snapshot.prompt
        workspaceName = snapshot.workspaceName
        selectedTemplateID = snapshot.templateID
        selectedModelID = selectedTemplate.flatMap {
            validatedModelID(
                snapshot.modelID,
                for: $0,
                previouslyValidModelID: snapshot.modelID
            )
        }
        explicitlySelectedModel = nil
        let effortModel = selectedModel ?? modelAvailability.defaultModel
        selectedEffortID = effortModel.flatMap { model in
            model.efforts.contains { $0.id == snapshot.effortID }
                ? snapshot.effortID
                : model.defaultEffortID
        }
        selectedMacDeviceID = snapshot.macDeviceID
        selectedMacInstanceTag = snapshot.macInstanceTag
        selectedWorkspaceGroupID = snapshot.workspaceGroupID
        pendingRestoredWorkspaceGroupID = snapshot.workspaceGroupID
        workspaceGroupSelectionRequiresResolution = false
        directory = snapshot.directory
        didEditDirectory = snapshot.didEditDirectory
        submissionIdentity.adoptResolvedRequest(snapshot)
    }

    /// Recompute the suggested directory unless the user hand-edited it.
    func syncSuggestedDirectory() {
        guard !didEditDirectory else { return }
        directory = Self.suggestedDirectory(
            template: selectedTemplate,
            macDeviceID: selectedMacDeviceID,
            instanceTag: selectedMacInstanceTag,
            templateStore: store.taskTemplateStore,
            openDirectory: Self.preferredOpenDirectory(
                workspaces: store.workspaces,
                selectedWorkspaceID: store.selectedWorkspaceID,
                macDeviceID: selectedMacDeviceID,
                connectedMacDeviceID: store.connectedMacDeviceID,
                instanceTag: selectedMacInstanceTag,
                connectedMacInstanceTag: store.connectedMacInstanceTag
            )
        )
    }

    /// Applies a composer mutation and keeps each text-entry update O(1).
    /// Text fields resolve effective equivalence on focus loss or submission;
    /// discrete controls can resolve immediately after their single mutation.
    func updateSubmissionRequest(
        reconcileRecovery: Bool = false,
        _ update: () -> Void
    ) {
        if submissionPhase.offersRetry {
            submissionPhase = .idle
        }
        failureText = nil
        failureTitleStyle = .launchFailed
        update()
        if !hasRecordedDraftChange {
            hasRecordedDraftChange = true
            store.recordAppEvent(
                .taskDraftChanged,
                correlationID: submissionIdentity.id.uuidString
            )
        }
        submissionIdentity.markRequestDirty()
        if var recovery = completedOperationRecovery {
            recovery.markCurrentRequestDifferent()
            completedOperationRecovery = recovery
            if reconcileRecovery {
                resolveCompletedOperationRecoveryAfterEditing()
            }
        }
        isStartAgainConfirmationPresented = false
    }

    var activeCompletedOperationRecovery: TaskComposerCompletedOperationRecovery? {
        guard completedOperationRecovery?.appliesToCurrentRequest == true else { return nil }
        return completedOperationRecovery
    }

    var blockingCompletedOperationRecovery: TaskComposerCompletedOperationRecovery? {
        guard completedOperationRecovery?.blocksSubmission == true else { return nil }
        return completedOperationRecovery
    }

    func resolveCompletedOperationRecoveryAfterEditing() {
        guard !workspaceGroupSelectionNeedsInventory,
              !workspaceGroupSelectionRequiresResolution else { return }
        guard let operationID = completedOperationRecovery?.submittedSnapshot.operationID else { return }
        reconcileCompletedOperationRecovery(
            with: makeSubmissionSnapshot(operationID: operationID)
        )
    }

    @discardableResult
    private func reconcileCompletedOperationRecovery(
        with currentSnapshot: MobileTaskSubmissionSnapshot?
    ) -> UUID? {
        guard var recovery = completedOperationRecovery else { return nil }
        let shouldRestoreRecoveryBanner = recovery.reconcileCurrentRequest(currentSnapshot)
        completedOperationRecovery = recovery
        guard recovery.appliesToCurrentRequest else {
            failureText = nil
            failureTitleStyle = .launchFailed
            return nil
        }
        if shouldRestoreRecoveryBanner {
            failureTitleStyle = .taskAccepted
            failureText = recoveryFailureMessage(for: recovery.phase)
        }
        return recovery.submittedSnapshot.operationID
    }

    func submissionSnapshot() -> MobileTaskSubmissionSnapshot? {
        let candidateID = submissionIdentity.id
        return submissionIdentity.resolveCurrentRequest {
            makeSubmissionSnapshot(operationID: candidateID)
        }
    }

    func draftSnapshot() -> MobileTaskComposerDraft {
        let resolved = submissionSnapshot()
        let completedOperationID: UUID?
        if workspaceGroupSelectionNeedsInventory || workspaceGroupSelectionRequiresResolution {
            // Keep a completed-operation anchor intact while the route is
            // reconnecting; comparing it to a deliberately withheld snapshot
            // would make a retry look like a new ungrouped request.
            completedOperationID = completedOperationRecovery?.submittedSnapshot.operationID
        } else {
            completedOperationID = reconcileCompletedOperationRecovery(with: resolved)
        }
        let persistedWorkspaceGroupID = resolved?.workspaceGroupID
            ?? pendingRestoredWorkspaceGroupID
            ?? selectedWorkspaceGroupID
        return MobileTaskComposerDraft(
            prompt: prompt,
            modelID: selectedModel?.id,
            effortID: selectedEffort?.id,
            templateID: selectedTemplateID,
            macDeviceID: selectedMacDeviceID.isEmpty ? nil : selectedMacDeviceID,
            macInstanceTag: selectedMacDeviceID.isEmpty ? nil : selectedMacInstanceTag,
            directory: directory,
            didEditDirectory: didEditDirectory,
            workspaceName: workspaceName,
            workspaceGroupID: persistedWorkspaceGroupID,
            operationID: resolved?.operationID ?? submissionIdentity.id,
            completedOperationID: completedOperationID
        )
    }

    private func makeSubmissionSnapshot(operationID: UUID) -> MobileTaskSubmissionSnapshot? {
        guard let selectedTemplate else { return nil }
        guard selectedWorkspaceGroupID == nil || resolvedWorkspaceGroupID != nil else {
            // Never construct an outbound snapshot that silently drops a
            // selected group while its exact Mac inventory is unavailable.
            return nil
        }
        return MobileTaskSubmissionSnapshot(
            template: selectedTemplate,
            prompt: prompt,
            modelID: selectedModel?.id,
            effortID: selectedEffort?.id,
            macDeviceID: selectedMacDeviceID,
            macInstanceTag: selectedMacInstanceTag,
            directory: directory,
            workspaceName: workspaceName,
            workspaceGroupID: resolvedWorkspaceGroupID,
            didEditDirectory: didEditDirectory,
            attachments: attachments.map(\.submissionAttachment),
            operationID: operationID
        )
    }
}
#endif
