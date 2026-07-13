#if os(iOS)
import CmuxMobileShellModel

extension TaskComposerSheet {
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
}
#endif
