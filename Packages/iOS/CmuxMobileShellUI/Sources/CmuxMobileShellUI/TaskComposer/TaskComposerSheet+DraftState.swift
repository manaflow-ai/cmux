#if os(iOS)
import CmuxMobileShellModel
import Foundation

extension TaskComposerSheet {
    func selectTemplate(_ template: MobileTaskTemplate, modelID: String? = nil) {
        let validatedModelID = validatedModelID(modelID, for: template)
        updateSubmissionRequest(reconcileRecovery: true) {
            selectedTemplateID = template.id
            selectedModelID = validatedModelID
            explicitlySelectedModel = nil
            if template.isPlainShell {
                removeStagedAttachmentFiles()
                attachments.removeAll()
            }
            syncSuggestedDirectory()
        }
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
        selectedMacDeviceID = snapshot.macDeviceID
        selectedMacInstanceTag = snapshot.macInstanceTag
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
            templateStore: store.taskTemplateStore,
            openDirectory: Self.preferredOpenDirectory(
                workspaces: store.workspaces,
                selectedWorkspaceID: store.selectedWorkspaceID,
                macDeviceID: selectedMacDeviceID,
                connectedMacDeviceID: store.connectedMacDeviceID
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
        let completedOperationID = reconcileCompletedOperationRecovery(with: resolved)
        return MobileTaskComposerDraft(
            prompt: prompt,
            modelID: selectedModel?.id,
            templateID: selectedTemplateID,
            macDeviceID: selectedMacDeviceID.isEmpty ? nil : selectedMacDeviceID,
            macInstanceTag: selectedMacDeviceID.isEmpty ? nil : selectedMacInstanceTag,
            directory: directory,
            didEditDirectory: didEditDirectory,
            workspaceName: workspaceName,
            operationID: resolved?.operationID ?? submissionIdentity.id,
            completedOperationID: completedOperationID
        )
    }

    private func makeSubmissionSnapshot(operationID: UUID) -> MobileTaskSubmissionSnapshot? {
        guard let selectedTemplate else { return nil }
        return MobileTaskSubmissionSnapshot(
            template: selectedTemplate,
            prompt: prompt,
            modelID: selectedModel?.id,
            macDeviceID: selectedMacDeviceID,
            macInstanceTag: selectedMacInstanceTag,
            directory: directory,
            workspaceName: workspaceName,
            didEditDirectory: didEditDirectory,
            attachments: attachments.map(\.submissionAttachment),
            operationID: operationID
        )
    }
}
#endif
