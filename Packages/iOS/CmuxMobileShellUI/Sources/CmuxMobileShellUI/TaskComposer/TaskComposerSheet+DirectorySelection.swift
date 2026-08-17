#if os(iOS)
import CMUXMobileCore
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
        updateSubmissionRequest(reconcileRecovery: true) {
            directory = path
            didEditDirectory = true
        }
        store.recordAppEvent(.taskDirectorySearchSucceeded, count: 1)
    }
}
#endif
