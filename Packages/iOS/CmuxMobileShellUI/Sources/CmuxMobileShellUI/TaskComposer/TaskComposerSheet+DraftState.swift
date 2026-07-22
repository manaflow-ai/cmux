#if os(iOS)
import CmuxMobileShellModel
import Foundation

extension TaskComposerSheet {
    func selectTemplate(_ template: MobileTaskTemplate) {
        updateSubmissionRequest {
            selectedTemplateID = template.id
            syncSuggestedDirectory()
        }
    }

    func restoreSubmittedDraft(_ snapshot: MobileTaskSubmissionSnapshot) {
        prompt = snapshot.prompt
        workspaceName = snapshot.workspaceName
        selectedTemplateID = snapshot.templateID
        selectedMacDeviceID = snapshot.macDeviceID
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

    /// Applies a composer mutation and keeps text-entry work O(1). Completed-
    /// operation recovery is conservatively blocked while a cancellable,
    /// debounced effective-request comparison is pending.
    func updateSubmissionRequest(_ update: () -> Void) {
        if submissionPhase.offersRetry {
            submissionPhase = .idle
        }
        failureText = nil
        failureTitleStyle = .launchFailed
        update()
        submissionIdentity.markRequestDirty()
        scheduleCompletedOperationRecoveryReconciliation()
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

    private func scheduleCompletedOperationRecoveryReconciliation() {
        guard var recovery = completedOperationRecovery else { return }
        recovery.markCurrentRequestUnresolved()
        completedOperationRecovery = recovery
        recoveryRequestReconciliationTask?.cancel()
        let operationID = recovery.submittedSnapshot.operationID
        recoveryRequestReconciliationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  completedOperationRecovery?.submittedSnapshot.operationID == operationID else { return }
            reconcileCompletedOperationRecovery(
                with: makeSubmissionSnapshot(operationID: operationID)
            )
            recoveryRequestReconciliationTask = nil
        }
    }

    @discardableResult
    private func reconcileCompletedOperationRecovery(
        with currentSnapshot: MobileTaskSubmissionSnapshot?
    ) -> UUID? {
        guard var recovery = completedOperationRecovery else { return nil }
        recovery.reconcileCurrentRequest(currentSnapshot)
        completedOperationRecovery = recovery
        guard recovery.appliesToCurrentRequest else {
            failureText = nil
            failureTitleStyle = .launchFailed
            return nil
        }
        failureTitleStyle = .taskAccepted
        failureText = Self.recoveryFailureMessage(for: recovery.phase)
        return recovery.submittedSnapshot.operationID
    }

    func submissionSnapshot() -> MobileTaskSubmissionSnapshot? {
        let candidateID = submissionIdentity.id
        return submissionIdentity.resolveCurrentRequest {
            makeSubmissionSnapshot(operationID: candidateID)
        }
    }

    func draftSnapshot() -> MobileTaskComposerDraft {
        recoveryRequestReconciliationTask?.cancel()
        recoveryRequestReconciliationTask = nil
        let candidateID = submissionIdentity.id
        let resolved = submissionIdentity.resolveCurrentRequest {
            makeSubmissionSnapshot(operationID: candidateID)
        }
        let completedOperationID = reconcileCompletedOperationRecovery(with: resolved)
        return MobileTaskComposerDraft(
            prompt: prompt,
            templateID: selectedTemplateID,
            macDeviceID: selectedMacDeviceID.isEmpty ? nil : selectedMacDeviceID,
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
            macDeviceID: selectedMacDeviceID,
            directory: directory,
            workspaceName: workspaceName,
            didEditDirectory: didEditDirectory,
            operationID: operationID
        )
    }
}
#endif
