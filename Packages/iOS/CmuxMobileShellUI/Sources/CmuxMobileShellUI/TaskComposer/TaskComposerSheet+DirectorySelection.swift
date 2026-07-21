#if os(iOS)
import CmuxMobileShellModel

extension TaskComposerSheet {
    var directoryCandidates: [MobileTaskDirectoryCandidate] {
        TaskComposerDirectoryCandidates(
            store: store,
            selectedMacDeviceID: selectedMacDeviceID,
            selectedTemplate: selectedTemplate
        ).make()
    }

    func selectDirectory(_ path: String) {
        guard !submissionPhase.disablesRequestEditing else { return }
        updateSubmissionRequest {
            directory = path
            didEditDirectory = true
        }
        failureText = nil
    }
}
#endif
