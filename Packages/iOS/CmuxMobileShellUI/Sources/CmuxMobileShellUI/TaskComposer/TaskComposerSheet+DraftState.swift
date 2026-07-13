#if os(iOS)
import CmuxMobileShellModel

extension TaskComposerSheet {
    func selectTemplate(_ template: MobileTaskTemplate) {
        updateSubmissionRequest {
            var draft = draftSnapshot()
            draft.selectTemplate(
                id: template.id,
                suggestedDirectory: Self.suggestedDirectory(
                    template: template,
                    macDeviceID: selectedMacDeviceID,
                    templateStore: store.taskTemplateStore
                )
            )
            selectedTemplateID = draft.templateID
            directory = draft.directory
            didEditDirectory = draft.didEditDirectory
        }
    }

    func restoreSubmittedDraft(_ snapshot: MobileTaskSubmissionSnapshot) {
        prompt = snapshot.prompt
        selectedTemplateID = snapshot.templateID
        selectedMacDeviceID = snapshot.macDeviceID
        directory = snapshot.directory
        didEditDirectory = snapshot.didEditDirectory
        submissionIdentity = MobileTaskSubmissionIdentity(id: snapshot.operationID)
    }

    /// Recompute the suggested directory unless the user hand-edited it.
    func syncSuggestedDirectory() {
        guard !didEditDirectory else { return }
        directory = Self.suggestedDirectory(
            template: selectedTemplate,
            macDeviceID: selectedMacDeviceID,
            templateStore: store.taskTemplateStore
        )
    }

    /// Applies a composer mutation and rotates the idempotency key only when
    /// the exact request sent to the Mac changes.
    func updateSubmissionRequest(_ update: () -> Void) {
        let before = submissionSnapshot()
        update()
        let after = submissionSnapshot()
        submissionIdentity.rotateIfRequestChanged(from: before, to: after)
    }

    func submissionSnapshot() -> MobileTaskSubmissionSnapshot? {
        guard let selectedTemplate else { return nil }
        return MobileTaskSubmissionSnapshot(
            template: selectedTemplate,
            prompt: prompt,
            macDeviceID: selectedMacDeviceID,
            directory: directory,
            didEditDirectory: didEditDirectory,
            operationID: submissionIdentity.id
        )
    }

    func draftSnapshot() -> MobileTaskComposerDraft {
        MobileTaskComposerDraft(
            prompt: prompt,
            templateID: selectedTemplateID,
            macDeviceID: selectedMacDeviceID.isEmpty ? nil : selectedMacDeviceID,
            directory: directory,
            didEditDirectory: didEditDirectory,
            operationID: submissionIdentity.id
        )
    }
}
#endif
