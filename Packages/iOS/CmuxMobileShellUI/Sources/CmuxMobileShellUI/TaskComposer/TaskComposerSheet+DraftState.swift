#if os(iOS)
import CmuxMobileShellModel
import Foundation

extension TaskComposerSheet {
    func selectTemplate(_ template: MobileTaskTemplate) {
        updateSubmissionRequest {
            selectedTemplateID = template.id
            guard !didEditDirectory else { return }
            directory = Self.suggestedDirectory(
                    template: template,
                    macDeviceID: selectedMacDeviceID,
                    templateStore: store.taskTemplateStore
            )
        }
    }

    func restoreSubmittedDraft(_ snapshot: MobileTaskSubmissionSnapshot) {
        prompt = snapshot.prompt
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

    /// Applies a composer mutation and defers request comparison to a low-
    /// frequency persistence or submission boundary.
    func updateSubmissionRequest(_ update: () -> Void) {
        if submissionPhase.offersRetry {
            submissionPhase = .idle
        }
        failureText = nil
        update()
        submissionIdentity.markRequestDirty()
        completedOperationRecovery = nil
        isStartAgainConfirmationPresented = false
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
            operationID: resolved?.operationID ?? submissionIdentity.id,
            completedOperationID: completedOperationRecovery?.submittedSnapshot.operationID
        )
    }

    private func makeSubmissionSnapshot(operationID: UUID) -> MobileTaskSubmissionSnapshot? {
        guard let selectedTemplate else { return nil }
        return MobileTaskSubmissionSnapshot(
            template: selectedTemplate,
            prompt: prompt,
            macDeviceID: selectedMacDeviceID,
            directory: directory,
            didEditDirectory: didEditDirectory,
            operationID: operationID
        )
    }
}
#endif
