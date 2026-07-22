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

    /// Applies a composer mutation. Ordinary edits stay O(1); while duplicate-
    /// prevention recovery is active, compare the effective request so harmless
    /// whitespace edits and edit-revert cycles keep the recovery guard.
    func updateSubmissionRequest(_ update: () -> Void) {
        if submissionPhase.offersRetry {
            submissionPhase = .idle
        }
        failureText = nil
        failureTitleStyle = .launchFailed
        update()
        submissionIdentity.markRequestDirty()
        reconcileCompletedOperationRecoveryWithCurrentRequest()
        isStartAgainConfirmationPresented = false
    }

    var activeCompletedOperationRecovery: TaskComposerCompletedOperationRecovery? {
        guard completedOperationRecovery?.appliesToCurrentRequest == true else { return nil }
        return completedOperationRecovery
    }

    private func reconcileCompletedOperationRecoveryWithCurrentRequest() {
        guard var recovery = completedOperationRecovery else { return }
        recovery.reconcileCurrentRequest(
            makeSubmissionSnapshot(operationID: recovery.submittedSnapshot.operationID)
        )
        completedOperationRecovery = recovery
        guard recovery.appliesToCurrentRequest else { return }
        failureTitleStyle = .taskAccepted
        failureText = Self.recoveryFailureMessage(for: recovery.phase)
    }

    func submissionSnapshot() -> MobileTaskSubmissionSnapshot? {
        let candidateID = submissionIdentity.id
        return submissionIdentity.resolveCurrentRequest {
            makeSubmissionSnapshot(operationID: candidateID)
        }
    }

    func draftSnapshot() -> MobileTaskComposerDraft {
        let candidateID = submissionIdentity.id
        let resolved = submissionIdentity.resolveCurrentRequest {
            makeSubmissionSnapshot(operationID: candidateID)
        }
        return MobileTaskComposerDraft(
            prompt: prompt,
            templateID: selectedTemplateID,
            macDeviceID: selectedMacDeviceID.isEmpty ? nil : selectedMacDeviceID,
            directory: directory,
            didEditDirectory: didEditDirectory,
            workspaceName: workspaceName,
            operationID: resolved?.operationID ?? submissionIdentity.id,
            completedOperationID: activeCompletedOperationRecovery?.submittedSnapshot.operationID
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
